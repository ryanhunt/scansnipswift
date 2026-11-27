extension VENS {
    /// Flag in a probe asking for a discovery reply.
    public static let discoveryFlag: UInt16 = 0x0010
    /// Flag in a probe that is a heartbeat (sent from `heartbeatSourcePort`, sequence 1). Without
    /// heartbeats the scanner ends a reservation about 40 s after registration, whatever commands it gets;
    /// open-scansnap sends one at least every 10 s (ScanSnap Home sends three every ~30 s).
    public static let heartbeatFlag: UInt16 = 0x1000

    /// A 32-byte UDP probe for `discoveryPort`:
    /// `VENS | u32 sequence | host IPv4 | host MAC | u32 0 | u16 reply port | u16 flag | 6 B zero`.
    /// The scanner ignores a probe without the host's IPv4 address but answers one whose MAC is all zeros,
    /// so a broadcast discovery probe need not carry an identifier (per open-scansnap).
    public static func probe(
        hostIP: [UInt8], hostMAC: [UInt8], replyPort: UInt16, flag: UInt16 = discoveryFlag, sequence: UInt32 = 0
    ) -> [UInt8] {
        precondition(hostIP.count == 4 && hostMAC.count == 6, "An IPv4 address is 4 bytes, a MAC 6")
        return magic + bigEndian(sequence) + hostIP + hostMAC + bigEndian(UInt32(0)) + bigEndian(replyPort)
            + bigEndian(flag) + [UInt8](repeating: 0, count: 6)
    }

    /// A scanner's 132-byte answer to a discovery probe.
    public struct Announcement: Sendable, Equatable {
        public static let length = 132

        /// The scanner's IPv4 address. Ignore a reply whose address differs from its sender.
        public let ipAddress: [UInt8]
        /// 6 on iX500 firmware 0U00, 4 on 0M00. Sent back in the registration.
        public let interfaceVersion: UInt16
        /// 0x30 on the iX500.
        public let deviceType: UInt16
        public let macAddress: [UInt8]
        /// 4 while a host is registered, 1 after power-on or unplugging USB, 2 while connected over USB
        /// (observed by ScanSnack; not fully understood).
        public let state: UInt32
        /// For example `iX500-A0XX012345`: the model and serial number, unless renamed (unverified).
        public let name: String
        /// For example `ScanSnap iX500` (trailing spaces trimmed).
        public let model: String
        /// IPv4 address of the host that registered last (0.0.0.0 if none).
        public let registeredHostIP: [UInt8]
        /// 8-byte ID of the registered host. Hosts are added to the scanner's table only over USB; an
        /// ID missing from it is refused with -7. On a Mac paired by ScanSnap Home, compute the ID with
        /// `VENS.hostID(mac:)` rather than trusting this field: it has been seen naming the connected
        /// host, and what it shows when none is connected is not yet known.
        public let registeredHostID: [UInt8]

        public init?(_ data: [UInt8]) {
            guard data.count >= Self.length, Array(data[0..<4]) == magic else { return nil }
            ipAddress = Array(data[16..<20])
            interfaceVersion = readUInt16(data, at: 8)
            deviceType = readUInt16(data, at: 10)
            macAddress = Array(data[28..<34])
            state = readUInt32(data, at: 36)
            name = asciiField(data[40..<104])
            model = asciiField(data[104..<120])
            registeredHostIP = Array(data[120..<124])
            registeredHostID = Array(data[124..<132])
        }

        /// The serial number, taken from the name after its last `-`.
        public var serialNumber: String? {
            guard let dash = name.lastIndex(of: "-") else { return nil }
            let serial = name[name.index(after: dash)...]
            return serial.isEmpty ? nil : String(serial)
        }

        /// The factory Wi-Fi password: the last four characters of the serial number.
        public var factoryPassword: String? {
            guard let serial = serialNumber, serial.count >= 4 else { return nil }
            return String(serial.suffix(4))
        }

        /// Whether a host ID is on record. Without one, ScanSnap Home has to set up Wi-Fi over USB first.
        public var hasRegisteredHost: Bool { registeredHostID.contains { $0 != 0 } }

        /// The model, if it is one this package knows.
        public var knownModel: ScanSnapModel? { ScanSnapModel.matching(announcedModel: model) }
    }

    /// A 48-byte UDP notice from the scanner: `u32 0x30 | VENS | u32 event | u32 0 | u8 counter`.
    /// Each is sent three times about 0.5 s apart; the counter tells repeats apart.
    public struct Notice: Sendable, Equatable {
        public enum Event: Sendable, Equatable {
            /// The Scan button (to `notificationPort` on the registered host).
            case scanButton
            /// The lid was closed, which turns the scanner off (to `notificationPort`).
            case lidClosed
            /// The lid was opened, about 10 s earlier (to `startupNoticePort`, broadcast and registered host).
            case lidOpened
            case other(UInt32)

            init(_ code: UInt32) {
                switch code {
                case 0x01: self = .scanButton
                case 0x10: self = .lidClosed
                case 0x21: self = .lidOpened
                default: self = .other(code)
                }
            }
        }

        public static let length = 48

        public let event: Event
        /// Restarts at 1 after power-on.
        public let counter: UInt8

        public init(event: Event, counter: UInt8) {
            self.event = event
            self.counter = counter
        }

        public init?(_ data: [UInt8]) {
            guard data.count >= Self.length, readUInt32(data, at: 0) == UInt32(Self.length),
                Array(data[4..<8]) == magic
            else { return nil }
            event = Event(readUInt32(data, at: 8))
            counter = data[16]
        }
    }

    static func asciiField(_ bytes: ArraySlice<UInt8>) -> String {
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return String(text.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
    }
}
