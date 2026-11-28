import ScanSnipProtocol
import ScanSnipScanner
@testable import ScanSnipUSB

/// An in-memory iX100 on USB that keeps the rules seen on hardware (2026-11-29): a sheet is loaded (status
/// byte 2 bit 7) a few polls after it is put in; a feed with no sheet answers 3/80/03; in ScanSnap Cloud mode
/// every feed answers 3/80/33; image reads are whole lines, and the last one comes back full length with CHECK
/// CONDITION, end of medium and incorrect length, the information field giving the bytes that are padding;
/// samples are inverted, lines in the order fed.
actor SimulatedUSBScanner: SCSIChannel {
    /// Line counts of the sheets the user will put in, in order.
    private var sheets: [Int]
    /// Status reads between a sheet going in and it being loaded.
    private let pollsBeforeLoaded: Int
    private var pollsForCurrentSheet = 0
    var cloudMode = false
    /// Transfers that fail before the scanner answers (it can miss the first after waking).
    private var failuresLeft: Int
    /// The first byte of each CDB run, in order.
    private(set) var opcodes: [UInt8] = []
    private var pendingSense: [UInt8]?
    private var pageData: [UInt8] = []
    private var width = 0
    /// Each page's upright image as the test expects it back.
    private(set) var uprightPages: [[UInt8]] = []

    init(sheets: [Int], pollsBeforeLoaded: Int = 2, failuresBeforeAnswering: Int = 0) {
        self.sheets = sheets
        self.pollsBeforeLoaded = pollsBeforeLoaded
        failuresLeft = failuresBeforeAnswering
    }

    func setCloudMode(_ on: Bool) { cloudMode = on }

    func run(_ cdb: [UInt8], output: [UInt8], inputLength: Int, timeout: Duration) async throws -> SCSIResult {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw ScannerError.network("USB write: Unable to send IO.")
        }
        opcodes.append(cdb[0])
        switch cdb[0] {
        case 0x03:
            let sense = pendingSense ?? Self.sense(key: 0)
            pendingSense = nil
            return good(Array(sense.prefix(inputLength)))
        case 0xC2:
            var status = [UInt8](repeating: 0, count: 0x20)
            if !sheets.isEmpty {
                pollsForCurrentSheet += 1
                if pollsForCurrentSheet > pollsBeforeLoaded { status[2] = 0x80 }
            }
            return good(status)
        case 0x24:
            // The descriptor's width in 1/1200 in, at 0x0E after the 8-byte header.
            let width1200 = Int(output[22]) << 24 | Int(output[23]) << 16 | Int(output[24]) << 8 | Int(output[25])
            let resolution = Int(output[10]) << 8 | Int(output[11])
            width = width1200 * resolution / 1200
            return good([])
        case 0x31 where cdb[1] == 0x01:
            if cloudMode { return check(Self.sense(key: 3, code: 0x80, qualifier: 0x33)) }
            guard !sheets.isEmpty, pollsForCurrentSheet > pollsBeforeLoaded else {
                return check(Self.sense(key: 3, code: 0x80, qualifier: 0x03))
            }
            let lines = sheets.removeFirst()
            pollsForCurrentSheet = 0
            // Pixel i is (i % 251, i % 241, i % 239). The scanner sends each sample inverted.
            let upright = (0..<(width * lines)).flatMap { i in [UInt8(i % 251), UInt8(i % 241), UInt8(i % 239)] }
            uprightPages.append(upright)
            pageData = upright.map { 255 - $0 }
            return good([])
        case 0x28 where cdb[2] == 0x80:
            return good(VENS.bigEndian(UInt32(width)) + VENS.bigEndian(UInt32(14 * 150)) + [UInt8](repeating: 0, count: 24))
        case 0x28:
            if pageData.count > inputLength {
                let chunk = Array(pageData.prefix(inputLength))
                pageData.removeFirst(inputLength)
                return good(chunk)
            }
            let missing = inputLength - pageData.count
            let chunk = pageData + [UInt8](repeating: 0, count: missing)
            pageData = []
            return check(Self.sense(key: 0, endOfMedium: true, incorrectLength: true, information: UInt32(missing)), data: chunk)
        default:
            return good([])
        }
    }

    func close() async {}

    private func good(_ data: [UInt8]) -> SCSIResult {
        SCSIResult(data: data, status: Self.status(FujitsuUSB.StatusPacket.good))
    }

    private func check(_ sense: [UInt8], data: [UInt8] = []) -> SCSIResult {
        pendingSense = sense
        return SCSIResult(data: data, status: Self.status(FujitsuUSB.StatusPacket.checkCondition))
    }

    static func status(_ scsiStatus: UInt8) -> FujitsuUSB.StatusPacket {
        var bytes = [0x53] + [UInt8](repeating: 0, count: 12)
        bytes[9] = scsiStatus
        return FujitsuUSB.StatusPacket(bytes)!
    }

    /// 18 bytes of fixed-format sense.
    static func sense(key: UInt8, code: UInt8 = 0, qualifier: UInt8 = 0, endOfMedium: Bool = false,
                      incorrectLength: Bool = false, information: UInt32 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 18)
        bytes[0] = 0x70
        bytes[2] = key | (endOfMedium ? 0x40 : 0) | (incorrectLength ? 0x20 : 0)
        bytes.replaceSubrange(3..<7, with: VENS.bigEndian(information))
        bytes[7] = 10
        bytes[12] = code
        bytes[13] = qualifier
        return bytes
    }
}
