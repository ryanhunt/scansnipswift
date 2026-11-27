/// Wire format of the ScanSnap iX500 Wi-Fi protocol ("VENS"). Pure values and functions, no I/O.
///
/// Adapted from holgerkrupp/Scan (`Scan/WiFiTransport/VENSProtocol.swift`, commit 413a7e5, MIT), which
/// follows the protocol write-up in elte0/scansnack (`docs/protocol-ix500.md`, commit cf3464f, MIT).
/// See docs/PROTOCOL-iX500-WiFi.md. Integers on the wire are big-endian.
///
/// Channels:
/// - UDP 52217 on the scanner: discovery and heartbeat (`probe`, `Announcement`).
/// - TCP 53219: control, one connection per command (registration, release, name, status).
/// - TCP 53218: a SCSI tunnel for scanning (`scsiFrame`, `SCSIReply`). One client at a time.
/// - UDP 55265 / 53220 on the host: notices for the Scan button, lid closed and lid opened (`Notice`).
public enum VENS {
    public static let magic: [UInt8] = Array("VENS".utf8)

    public static let discoveryPort: UInt16 = 52217
    public static let scanPort: UInt16 = 53218
    public static let controlPort: UInt16 = 53219
    /// Host port that receives the Scan-button and lid-closed notices, sent in the registration.
    public static let notificationPort: UInt16 = 55265
    /// Host port (and broadcast) that receives the lid-opened notice. Configurable in ScanSnap Home.
    public static let startupNoticePort: UInt16 = 53220
    /// Source port ScanSnap Home uses for heartbeats.
    public static let heartbeatSourcePort: UInt16 = 55264

    /// Client frames start with a 32-byte header; the scanner's with a 16-byte one.
    public static let clientHeaderLength = 32
    public static let serverHeaderLength = 16
    /// Length of the header in front of the data in a reply on the scan channel.
    public static let scsiReplyHeaderLength = 40
    /// Largest frame accepted from the scanner (a guard against a corrupt length).
    public static let maximumFrameLength = 0x40_0000

    /// Control-channel commands (the `command` field of a client frame).
    public enum ControlCommand: UInt32, Sendable {
        /// Run a SCSI command on the scan channel.
        case scsi = 0x01
        /// Register this host for a session (`registrationBody`). Starts a reservation keyed to the
        /// frame's MAC; keep it alive with heartbeats (`heartbeatFlag`).
        case register = 0x11
        /// End this client's reservation: a client frame with no body. Only the holder's release counts.
        /// From thomergil/open-scansnap (ScanSnap Home's `SsSvcPCWIFITelReleaseScanner`).
        case release = 0x12
        /// Read the scanner's name (64 bytes).
        case name = 0x13
        /// Read a status word (3 observed on mains power; meaning unknown).
        case status = 0x30
    }

    /// A frame from this host: `u32 length | VENS | u32 command | u32 0 | 6 B MAC | 10 B zero | body`.
    ///
    /// The MAC is the session identity: the scan channel only answers the MAC that sent the last
    /// registration, and another MAC's registration gets -4 (busy) while that reservation lasts. The scanner
    /// accepts any MAC, so it need not be the interface's real one (macOS and iOS hide that): use a stable,
    /// locally administered MAC per host, as thomergil/open-scansnap does.
    public static func clientFrame(command: UInt32, mac: [UInt8], body: [UInt8] = []) -> [UInt8] {
        precondition(mac.count == 6, "A MAC address is 6 bytes")
        return bigEndian(UInt32(clientHeaderLength + body.count)) + magic + bigEndian(command) + bigEndian(UInt32(0))
            + mac + [UInt8](repeating: 0, count: 10) + body
    }

    /// The total length of a frame from the scanner, read from its first 8 bytes (`u32 length | VENS`).
    /// Read that many bytes in all, including these 8.
    public static func frameLength(header: some Collection<UInt8>) throws(VENSError) -> Int {
        let head = Array(header.prefix(8))
        guard head.count == 8 else { throw .truncated(expected: 8, actual: head.count) }
        guard Array(head[4..<8]) == magic else { throw .badMagic }
        let length = Int(readUInt32(head, at: 0))
        guard (serverHeaderLength...maximumFrameLength).contains(length) else { throw .badLength(length) }
        return length
    }

    /// A SCSI command for the scan channel: a client frame (command 1) with a 16-byte parameter header
    /// (`u32 CDB length | u32 bytes wanted back | u32 bytes sent | u32 0`), the CDB padded to 16 bytes,
    /// and the data sent with it.
    public static func scsiFrame(mac: [UInt8], cdb: [UInt8], output: [UInt8] = [], inputLength: Int = 0) -> [UInt8] {
        precondition(cdb.count <= 16, "A CDB is at most 16 bytes")
        let header = bigEndian(UInt32(cdb.count)) + bigEndian(UInt32(inputLength)) + bigEndian(UInt32(output.count))
            + bigEndian(UInt32(0))
        let body = header + cdb + [UInt8](repeating: 0, count: 16 - cdb.count) + output
        return clientFrame(command: ControlCommand.scsi.rawValue, mac: mac, body: body)
    }

    /// The scanner's answer to `scsiFrame`: a SCSI status and any data read.
    public struct SCSIReply: Sendable, Equatable {
        /// SCSI CHECK CONDITION: send REQUEST SENSE (`Command.requestSense`) to learn why.
        public static let checkCondition: UInt32 = 2

        public let status: UInt32
        public let data: [UInt8]

        public var isGood: Bool { status == 0 }
        public var isCheckCondition: Bool { status == Self.checkCondition }

        public init(status: UInt32, data: [UInt8]) {
            self.status = status
            self.data = data
        }

        /// Parses a whole frame read from the scan channel (header included).
        public init(frame: [UInt8]) throws(VENSError) {
            guard frame.count >= scsiReplyHeaderLength else {
                throw .truncated(expected: scsiReplyHeaderLength, actual: frame.count)
            }
            guard Array(frame[4..<8]) == magic else { throw .badMagic }
            status = readUInt32(frame, at: 12)
            data = Array(frame[scsiReplyHeaderLength...])
        }
    }

    // MARK: Byte helpers

    public static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

/// A reply that does not follow the VENS wire format.
public enum VENSError: Error, Sendable, Equatable {
    /// The frame does not carry the `VENS` magic.
    case badMagic
    /// A frame length outside what the scanner sends.
    case badLength(Int)
    /// Fewer bytes than the format needs.
    case truncated(expected: Int, actual: Int)
    /// An image read answered with another image index or chunk number than the one asked for.
    case unexpectedImageChunk(expectedIndex: UInt8, expectedChunk: UInt8, actualIndex: UInt8, actualChunk: UInt8)
    /// A password longer than the 16 characters the registration can carry.
    case passwordTooLong
}
