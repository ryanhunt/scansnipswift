extension VENS {
    /// SCSI command blocks the iX500 accepts on the Wi-Fi scan channel. This is a vendor set of its own,
    /// not the one used over USB: the Wi-Fi firmware rejects SET WINDOW, OBJECT POSITION, SCAN and the other
    /// standard scan commands (sense 5/20/00). Names follow ScanSnap Home's `SsSvcPCWIFITel*` classes, as
    /// recorded by thomergil/open-scansnap.
    ///
    /// A scan session runs: `hardwareStatus`, `startJob` (8 bytes out, 8 in), `cancelRead`,
    /// `setPreReadMode` (`windowBlock`), `setParameters` (`parameterBlock`), `hardwareStatus`,
    /// `requestSense`; then per sheet `startPaper`, `readImage` front, `readImage` back, `imageInfo`,
    /// `hardwareStatus`; finally `endJob` on a new connection once the scan connection is closed.
    /// `endJob` ends the job, not the reservation: see `ControlCommand.release`.
    public enum Command {
        /// Hardware status, 0x20 bytes back. See `hopperHasPaper(_:)`.
        public static let hardwareStatus: [UInt8] = [0xC2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0]
        /// Start a job: 8 bytes out, 8 back.
        public static let startJob: [UInt8] = [0xD5, 0, 0, 0, 8, 8]
        /// Sent once before the scan settings.
        public static let cancelRead: [UInt8] = [0xD8, 0, 0, 0, 0, 0]
        /// Resolution and scan area: 32 bytes out (`windowBlock`).
        public static let setPreReadMode: [UInt8] = [0xE9, 0, 0, 0, 0, 0, 0, 0x20, 0, 0]
        /// Scan parameters: 80 bytes out (`parameterBlock`).
        public static let setParameters: [UInt8] = [0xD4, 0, 0, 0, 0x50, 0]
        /// Feed a sheet. CHECK CONDITION with sense 3/80/03 means the feeder is empty (or the job ended).
        public static let startPaper: [UInt8] = [0xE0, 0, 0, 0, 0, 0]
        /// End the job; send it on a new connection after closing the scan connection.
        public static let endJob: [UInt8] = [0xD6, 0, 0, 0, 0, 0]
        /// REQUEST SENSE, 18 bytes back. See `SCSISense`.
        public static let requestSense: [UInt8] = [0x03, 0, 0, 0, 0x12, 0]
        /// INQUIRY, 96 bytes back. The firmware revision follows the product name.
        public static let inquiry: [UInt8] = [0x12, 0, 0, 0, 0x60, 0]
        /// Page counters, 0x20 bytes back: u32 total pages, then two more u32 (probably roller counts).
        public static let counters: [UInt8] = [0xD9, 0, 0, 0, 0x20, 0]
    }

    /// Bytes asked for per image read. A whole 300 dpi colour side has fitted in one read so far.
    public static let readLength = 0x30_0000
    /// The image index is one byte and counts sides: start a new job well before it wraps.
    public static let maximumSheetsPerJob = 120

    /// Read a side's JPEG. `imageIndex` counts sides from 0 in a job: front `2n`, back `2n + 1`.
    /// The reply ends with CHECK CONDITION and an end-of-medium sense once the image is complete;
    /// each reply's data starts with an `ImageChunk` header.
    public static func readImageCommand(back: Bool, imageIndex: Int) -> [UInt8] {
        [0x28, 0, 0, 2, 0, back ? 0x80 : 0, UInt8(readLength >> 16 & 0xFF), UInt8(readLength >> 8 & 0xFF),
         UInt8(readLength & 0xFF), 0, UInt8(imageIndex & 0xFF), 0]
    }

    /// Image information after both sides of a sheet, 0x20 bytes back. Send the back's index.
    /// Holds width, maximum height, width, height and x/y resolution (field sizes not yet confirmed).
    public static func imageInfoCommand(imageIndex: Int) -> [UInt8] {
        [0x28, 0, 0x80, 0, 0, 0x80, 0, 0, 0x20, 0, UInt8(imageIndex & 0xFF), 0]
    }

    /// The two-byte header in front of each piece of a side's JPEG: the image index, then the chunk number.
    public struct ImageChunk: Sendable, Equatable {
        public let imageIndex: UInt8
        public let chunk: UInt8
        public let bytes: ArraySlice<UInt8>

        /// Splits a read's data and checks it belongs to the image and chunk asked for.
        public init(data: [UInt8], imageIndex: Int, chunk: Int) throws(VENSError) {
            guard data.count >= 2 else { throw .truncated(expected: 2, actual: data.count) }
            let expectedIndex = UInt8(imageIndex & 0xFF)
            let expectedChunk = UInt8(chunk & 0xFF)
            guard data[0] == expectedIndex, data[1] == expectedChunk else {
                throw .unexpectedImageChunk(
                    expectedIndex: expectedIndex, expectedChunk: expectedChunk, actualIndex: data[0], actualChunk: data[1])
            }
            self.imageIndex = data[0]
            self.chunk = data[1]
            bytes = data[2...]
        }
    }

    /// Whether the feeder holds paper, from a `Command.hardwareStatus` reply (byte 3, bit 7 clear).
    /// After `startPaper` reports an empty feeder, this tells the end of a job from a really empty feeder.
    public static func hopperHasPaper(_ status: [UInt8]) -> Bool? {
        status.count > 3 ? status[3] & 0x80 == 0 : nil
    }

    // MARK: Scan settings

    /// Page sizes in 1/1200 inch, as ScanSnap Home sends them.
    public enum PageSize: Sendable, Hashable, CaseIterable {
        /// Detect the page size (the scanner scans the whole area; crop on the host).
        case automatic
        case a4, letter, legal, b5, a5, b6

        /// Width and height in 1/1200 inch.
        public var size: (width: UInt32, height: UInt32) {
            switch self {
            case .automatic: (0x28D0, 0x44DC)
            case .a4: (0x26C1, 0x36D0)
            case .letter: (0x27D8, 0x3390)
            case .legal: (0x27D8, 0x41A0)
            case .b5: (0x2196, 0x2F6E)
            case .a5: (0x1B50, 0x26C1)
            case .b6: (0x179F, 0x2196)
            }
        }
    }

    /// What a scan asks for. The iX500 always scans in colour and always reads both sides; grey,
    /// black and white, single-sided output, blank-page removal and deskew happen on the host.
    /// Pages arrive as colour JPEGs rotated by 180°.
    public struct ScanParameters: Sendable, Hashable {
        public static let resolutions = [150, 200, 300, 600]

        public var resolution: Int
        public var pageSize: PageSize
        /// Ultrasonic double-feed detection.
        public var detectsDoubleFeed: Bool

        public init(resolution: Int = 300, pageSize: PageSize = .automatic, detectsDoubleFeed: Bool = true) {
            self.resolution = resolution
            self.pageSize = pageSize
            self.detectsDoubleFeed = detectsDoubleFeed
        }

        public var isValid: Bool { Self.resolutions.contains(resolution) }
    }

    /// `setPreReadMode` data:`u16 dpi x | u16 dpi y | u32 width | u32 height | 05`, padded to 32 bytes.
    public static func windowBlock(_ parameters: ScanParameters) -> [UInt8] {
        precondition(parameters.isValid, "Unsupported resolution \(parameters.resolution)")
        let dpi = UInt16(parameters.resolution)
        let size = parameters.pageSize.size
        let block = bigEndian(dpi) + bigEndian(dpi) + bigEndian(size.width) + bigEndian(size.height) + [0x05]
        return block + [UInt8](repeating: 0, count: 32 - block.count)
    }

    /// `setParameters` data: 32 bytes of scan parameters, then a 48-byte window descriptor.
    /// The colour / 300 dpi / automatic block matches ScanSnap Home's byte for byte (per ScanSnack's captures).
    public static func parameterBlock(_ parameters: ScanParameters) -> [UInt8] {
        precondition(parameters.isValid, "Unsupported resolution \(parameters.resolution)")
        let dpi = parameters.resolution
        let automatic: UInt8 = parameters.pageSize == .automatic ? 1 : 0
        var block = [UInt8](repeating: 0, count: 32)
        block[1] = 3
        block[2] = automatic
        block[3] = automatic
        block[4] = parameters.detectsDoubleFeed ? 0xD0 : 0x00
        block[6] = 0xC1
        block.replaceSubrange(7...9, with: [0x80, 0x80, 0x80])
        block[10] = dpi == 300 ? 0x90 : 0x80
        block.replaceSubrange(11...12, with: [0x80, 0x80])
        block[13] = dpi == 600 ? 0x80 : 0x00
        block[31] = 0x30

        let quality: UInt8 = switch dpi {
        case 300: 0
        case 600: 0x0A
        default: 5
        }
        let size = parameters.pageSize.size
        var descriptor: [UInt8] = [0x00, 0x10] + bigEndian(UInt16(dpi)) + bigEndian(UInt16(dpi)) + [5, 0x81, quality, 0]
        descriptor += bigEndian(size.width) + bigEndian(size.height) + [0x04]
        descriptor += [UInt8](repeating: 0, count: 48 - descriptor.count)
        return block + descriptor
    }
}
