/// Fixed-format SCSI sense data (the reply to REQUEST SENSE), as ScanSnap scanners send it over USB
/// and Wi-Fi.
public struct SCSISense: Sendable, Equatable, CustomStringConvertible {
    /// Something the person at the scanner can fix.
    public enum PaperProblem: Sendable, Equatable {
        /// 3/80/03. Also what a feed returns at the end of a job, so check the hopper sensor.
        case feederEmpty
        /// 3/80/01.
        case jam
        /// 3/80/02 (from holgerkrupp/Scan; not yet seen by this package).
        case coverOpen
        /// 3/80/07: several sheets went through together.
        case doubleFeed
        /// 3/80/33: the scanner will not move paper for this computer. An iX100 answered it to every command
        /// that moves paper over USB while in ScanSnap Cloud mode (Scan button lit purple after power-on), and
        /// scanned normally with its Wi-Fi switched off (2026-11-29). Tell the user to turn Cloud mode off in
        /// ScanSnap Home or switch the scanner's Wi-Fi off. ScanSnap Manager's files suggest a scanner held by
        /// a mobile device refuses the same way.
        case heldByCloudOrMobile
        /// Another 3/80/xx code.
        case other(UInt8)
    }

    public let key: UInt8
    public let additionalCode: UInt8
    public let additionalQualifier: UInt8
    /// End of medium: a read reached the end of the image.
    public let endOfMedium: Bool
    /// Incorrect length: the read returned fewer bytes than asked for.
    public let incorrectLength: Bool
    /// The information field (bytes 3 to 6); with `incorrectLength`, how many bytes were not sent.
    public let information: UInt32

    public init?(_ data: [UInt8]) {
        guard data.count >= 14 else { return nil }
        key = data[2] & 0x0F
        endOfMedium = data[2] & 0x40 != 0
        incorrectLength = data[2] & 0x20 != 0
        information = UInt32(data[3]) << 24 | UInt32(data[4]) << 16 | UInt32(data[5]) << 8 | UInt32(data[6])
        additionalCode = data[12]
        additionalQualifier = data[13]
    }

    /// The paper problem this sense reports, or nil for anything else.
    public var paperProblem: PaperProblem? {
        guard key == 3, additionalCode == 0x80 else { return nil }
        switch additionalQualifier {
        case 0x01: return .jam
        case 0x02: return .coverOpen
        case 0x03: return .feederEmpty
        case 0x07: return .doubleFeed
        case 0x33: return .heldByCloudOrMobile
        default: return .other(additionalQualifier)
        }
    }

    public var description: String {
        let hex = [key, additionalCode, additionalQualifier].map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }
        return "sense " + hex.joined(separator: "/")
    }
}
