extension VENS {
    /// The scanner's answer to the control-channel status request (`ControlCommand.status`, after registering).
    ///
    /// The iX100 answers 32 bytes: the 16-byte server header, a u32 status word (3, or 2 right after it was
    /// turned on), then `02 00`, a flags byte and the battery level in percent. Seen on firmware 0V00,
    /// 27-28 Nov 2026: the level fell from 0x64 (100) to 0x06 over an evening on battery, and the flags byte
    /// read 0x80, or 0xC0 at 6%. ScanSnack saw only the status word on the iX500, which has no battery.
    public struct ControlStatus: Sendable, Equatable {
        /// 3 in use, 2 right after power-on (meaning otherwise unknown).
        public let word: UInt32
        /// The battery level in percent, if the scanner reports one (the iX100 does; the iX500 has no battery).
        public let batteryPercent: Int?
        /// Bit 0x40 of the flags byte, seen set only with the battery at 6%: probably "battery low".
        public let batteryLow: Bool

        public init(word: UInt32, batteryPercent: Int?, batteryLow: Bool) {
            self.word = word
            self.batteryPercent = batteryPercent
            self.batteryLow = batteryLow
        }

        /// Parses a whole reply frame (header included). Nil if it is shorter than the status word.
        public init?(reply: [UInt8]) {
            guard reply.count >= 20, Array(reply[4..<8]) == magic else { return nil }
            word = readUInt32(reply, at: 16)
            if reply.count >= 24, reply[20] == 0x02, reply[23] <= 100 {
                batteryPercent = Int(reply[23])
                batteryLow = reply[22] & 0x40 != 0
            } else {
                batteryPercent = nil
                batteryLow = false
            }
        }
    }

    /// The page counters (`Command.counters`, 0x20 bytes back): three big-endian u32 values, then 20 reserved
    /// bytes. ScanSnap Manager calls the command GET CONSUMABLES INFO and shows a total page count and, per
    /// model, the count since each consumable was last replaced: on the iX500 one roller set (pick and brake
    /// roller; `ScanSnapModel.rollerSetReplacementSheets`). So `others` is most likely the roller set's count,
    /// then a pad count the iX500 does not use; unverified on hardware. The iX100 has no consumables and
    /// reported three equal values.
    public struct PageCounters: Sendable, Equatable {
        public let pages: UInt32
        public let others: [UInt32]

        public init?(data: [UInt8]) {
            guard data.count >= 4 else { return nil }
            pages = readUInt32(data, at: 0)
            others = stride(from: 4, to: min(data.count, 12) - 3, by: 4).map { readUInt32(data, at: $0) }
        }
    }

    /// The standard SCSI INQUIRY answer (`Command.inquiry`): vendor, product and firmware revision, for example
    /// `FUJITSU`, `ScanSnap iX100` and `0V00`.
    public struct Inquiry: Sendable, Equatable {
        public let vendor: String
        public let product: String
        public let revision: String

        public init?(data: [UInt8]) {
            guard data.count >= 36 else { return nil }
            vendor = asciiField(data[8..<16])
            product = asciiField(data[16..<32])
            revision = asciiField(data[32..<36])
        }
    }
}
