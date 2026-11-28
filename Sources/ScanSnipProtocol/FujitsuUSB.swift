/// Wire format of Fujitsu's SCSI-over-USB, as the iX500 and iX100 use it. Pure values and functions, no I/O.
///
/// Each command is a 31-byte block on the bulk OUT endpoint, then any data out on bulk OUT or data in on
/// bulk IN, then a 13-byte status packet on bulk IN. Facts from holgerkrupp/Scan
/// (`FujitsuScanSnapDevice.swift`, 2026), whose USB code partly derives from SANE (GPL): only the layout is
/// taken here, the code is our own. Checked on an iX100 on 2026-11-29 (INQUIRY and hardware status).
public enum FujitsuUSB {
    public static let vendorID: UInt16 = 0x04C5
    /// The command block's length.
    public static let commandBlockLength = 31
    /// Where the SCSI command (CDB) starts in the block.
    public static let cdbOffset = 0x13
    /// The longest CDB that fits.
    public static let maximumCDBLength = commandBlockLength - cdbOffset
    /// The status packet's length.
    public static let statusPacketLength = 13

    /// The block that carries `cdb`: byte 0 `0x43`, the CDB at `cdbOffset`, zeros elsewhere.
    public static func commandBlock(_ cdb: [UInt8]) -> [UInt8] {
        precondition(!cdb.isEmpty && cdb.count <= maximumCDBLength, "A CDB is 1 to \(maximumCDBLength) bytes")
        var block = [UInt8](repeating: 0, count: commandBlockLength)
        block[0] = 0x43
        block.replaceSubrange(cdbOffset..<(cdbOffset + cdb.count), with: cdb)
        return block
    }

    /// The 13-byte packet after each command. Byte 0 was `0x53` ("S") on the iX100; byte 9 is the SCSI status.
    public struct StatusPacket: Sendable, Equatable {
        public static let good: UInt8 = 0
        public static let checkCondition: UInt8 = 2
        /// Treated as busy by Scan.
        public static let busy: UInt8 = 8

        public let bytes: [UInt8]

        /// Nil unless exactly `statusPacketLength` bytes.
        public init?(_ bytes: [UInt8]) {
            guard bytes.count == statusPacketLength else { return nil }
            self.bytes = bytes
        }

        public var scsiStatus: UInt8 { bytes[9] }
        public var isGood: Bool { scsiStatus == Self.good }
        /// Send REQUEST SENSE to learn why.
        public var isCheckCondition: Bool { scsiStatus == Self.checkCondition }
    }
}

// MARK: Scanning commands

extension FujitsuUSB {
    /// The SCSI commands a USB scan uses, as CDBs. The sequence and bytes are facts from holgerkrupp/Scan's iX500
    /// driver (`FujitsuScanSnapDevice.swift`); checked on an iX100 on 2026-11-29, which accepted all of them
    /// once ScanSnap Cloud mode was off. The Wi-Fi vendor commands (`D9`, `E7`) are refused over USB.
    public enum Command {
        public static let testUnitReady: [UInt8] = [0x00, 0, 0, 0, 0, 0]
        /// Standard INQUIRY, 0x60 bytes back (`VENS.Inquiry` reads it).
        public static let inquiry: [UInt8] = [0x12, 0, 0, 0, 0x60, 0]
        /// REQUEST SENSE, 0x12 bytes back (`SCSISense`).
        public static let requestSense: [UInt8] = [0x03, 0, 0, 0, 0x12, 0]
        /// Hardware status, 0x20 bytes back, as over Wi-Fi: byte 2 bit 7 is set once a sheet is loaded.
        public static let hardwareStatus: [UInt8] = [0xC2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0]
        /// Use the sheet feeder (vendor command `F1`, function 0).
        public static let selectFeeder: [UInt8] = [0xF1, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]
        /// Turn the lamp on (`F1`, function 5).
        public static let lampOn: [UInt8] = [0xF1, 0x05, 0, 0, 0, 0, 0, 0, 0, 0]
        /// Cancel the scan (`F1`, function 4).
        public static let cancel: [UInt8] = [0xF1, 0x04, 0, 0, 0, 0, 0, 0, 0, 0]
        /// OBJECT POSITION, load: feeds the loaded sheet. With no sheet it answers 3/80/03, which ends a job; with
        /// ScanSnap Cloud mode on it answers 3/80/33.
        public static let feed: [UInt8] = [0x31, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]
        /// OBJECT POSITION, halt: stops and ejects.
        public static let halt: [UInt8] = [0x31, 0x04, 0, 0, 0, 0, 0, 0, 0, 0]
        /// SCAN with a one-byte window list (`[0]`, the front) as its data.
        public static let scan: [UInt8] = [0x1B, 0, 0, 0, 1, 0]
        /// READ of the page's pixel size (data type 0x80), 0x20 bytes back (`PixelSize`).
        public static let readPixelSize: [UInt8] = [0x28, 0, 0x80, 0, 0, 0, 0, 0, 0x20, 0]

        /// READ of image data (data type 0), at most `length` bytes (24 bits).
        public static func readImage(length: Int) -> [UInt8] {
            [0x28, 0, 0, 0, 0, 0] + transferLength(length) + [0]
        }

        /// SEND DIAGNOSTIC with `length` bytes of parameters (the pre-read setup sends 32).
        public static func sendDiagnostic(length: Int) -> [UInt8] {
            precondition(length <= 0xFF, "At most 255 bytes")
            return [0x1D, 0, 0, 0, UInt8(length), 0]
        }

        /// MODE SELECT(6) with page format, `length` bytes of data.
        public static func modeSelect(length: Int) -> [UInt8] {
            precondition(length <= 0xFF, "At most 255 bytes")
            return [0x15, 0x10, 0, 0, UInt8(length), 0]
        }

        /// SET WINDOW, `length` bytes of data.
        public static func setWindow(length: Int) -> [UInt8] {
            [0x24, 0, 0, 0, 0, 0] + transferLength(length) + [0]
        }

        /// SEND of a gamma table (data type 0x83), `length` bytes of data.
        public static func sendGamma(length: Int) -> [UInt8] {
            [0x2A, 0, 0x83, 0, 0, 0] + transferLength(length) + [0]
        }

        private static func transferLength(_ length: Int) -> [UInt8] {
            precondition(length >= 0 && length <= 0xFF_FFFF, "A transfer length is 24 bits")
            return [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        }
    }

    /// A colour scan's area and resolution, and the data the setup commands send for it. The width is 8.5 in and
    /// the length up to 14 in; the scanner finds the page's real length (MODE SELECT page `3C`) and ends the
    /// image there.
    public struct Window: Sendable, Equatable {
        /// Dots per inch, the same across and along the page.
        public let resolution: Int

        public init(resolution: Int) {
            precondition(resolution > 0 && resolution <= 1200, "A resolution is 1 to 1200 dpi")
            self.resolution = resolution
        }

        /// Pixels across: 8.5 in, rounded down to an even number.
        public var widthPixels: Int { (85 * resolution / 10) & ~1 }
        /// The longest page, in lines: 14 in.
        public var maximumLines: Int { 14 * resolution }
        /// Bytes in one line of 8-bit RGB.
        public var bytesPerLine: Int { widthPixels * 3 }
        /// The width and length in 1/1200 in, the unit of the window and pre-read data.
        var width1200: Int { widthPixels * 1200 / resolution }
        var length1200: Int { maximumLines * 1200 / resolution }

        /// The 32 bytes of SEND DIAGNOSTIC "SET PRE READMODE": the name, resolution twice (u16), the paper's
        /// width + 1 and length + 2 (u32, 1/1200 in), colour (5), zeros.
        public var preReadData: [UInt8] {
            var data = Array("SET PRE READMODE".utf8) + VENS.bigEndian(UInt16(resolution)) + VENS.bigEndian(UInt16(resolution))
            data += VENS.bigEndian(UInt32(width1200 + 1)) + VENS.bigEndian(UInt32(length1200 + 2)) + [5]
            return data + [UInt8](repeating: 0, count: 32 - data.count)
        }

        /// The MODE SELECT data sent before a scan, in order: automatic page length on (`3C`), multifeed
        /// detection off (`38`), dropout colour default (`39`), buffering off (`3A`).
        public static let modePages: [[UInt8]] = [
            modePage(0x3C, [0, 0x80, 0, 0, 0, 0]),
            modePage(0x38, [0x80, 0, 0, 0, 0, 0]),
            modePage(0x39, [0, 0, 0, 0, 0, 0, 0, 0]),
            modePage(0x3A, [0x80, 0xC0, 0, 0, 0, 0]),
        ]

        /// The MODE SELECT data sent after a job: buffering off and cleared (`3A`).
        public static let endPage: [UInt8] = modePage(0x3A, [0x80, 0xC0, 0, 0, 0, 0])

        static func modePage(_ code: UInt8, _ body: [UInt8]) -> [UInt8] {
            [0, 0, 0, 0, code, UInt8(body.count)] + body
        }

        /// SET WINDOW's data: an 8-byte header (descriptor length 64 at byte 7), then one 64-byte window
        /// descriptor for the front: resolution at 2 and 4, width at 0x0E and length at 0x12 (1/1200 in),
        /// composition 5 (colour) at 0x19, 8 bits at 0x1A, vendor colour code 0xC1 at 0x28, downloaded gamma
        /// (0x80) at 0x29, RGB pixels (1) at 0x2A, a custom paper size (0xC0) at 0x35 with its width + 1 and
        /// length + 2 at 0x36 and 0x3A.
        public var windowData: [UInt8] {
            var descriptor = [UInt8](repeating: 0, count: 64)
            func put(_ bytes: [UInt8], at offset: Int) {
                descriptor.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            }
            put(VENS.bigEndian(UInt16(resolution)), at: 0x02)
            put(VENS.bigEndian(UInt16(resolution)), at: 0x04)
            put(VENS.bigEndian(UInt32(width1200)), at: 0x0E)
            put(VENS.bigEndian(UInt32(length1200)), at: 0x12)
            descriptor[0x19] = 5
            descriptor[0x1A] = 8
            descriptor[0x28] = 0xC1
            descriptor[0x29] = 0x80
            descriptor[0x2A] = 0x01
            descriptor[0x35] = 0xC0
            put(VENS.bigEndian(UInt32(width1200 + 1)), at: 0x36)
            put(VENS.bigEndian(UInt32(length1200 + 2)), at: 0x3A)
            return [0, 0, 0, 0, 0, 0, 0, 64] + descriptor
        }

        /// SEND gamma's data: a 10-byte header (`00 00 10 00 01 00 01 00 00 00`), then a straight 256-entry
        /// table (entry n is n).
        public static let linearGamma: [UInt8] = [0, 0, 0x10, 0, 0x01, 0x00, 0x01, 0x00, 0, 0] + (0...255).map { UInt8($0) }

        /// The most bytes of whole lines that fit in one image read of at most `limit` bytes.
        public func readLength(limit: Int = 0x40000) -> Int {
            max(1, limit / bytesPerLine) * bytesPerLine
        }
    }

    /// The answer to `Command.readPixelSize`: the page's width and length in pixels, big-endian u32 at 0 and 4
    /// (the window's size, not the page's: the image's real length shows when its reads end).
    public struct PixelSize: Sendable, Equatable {
        public let width: Int
        public let lines: Int

        public init?(data: [UInt8]) {
            guard data.count >= 8 else { return nil }
            width = Int(VENS.readUInt32(data, at: 0))
            lines = Int(VENS.readUInt32(data, at: 4))
        }
    }

    /// Turns the scanner's colour samples into ordinary RGB: they come inverted (255 is black). Lines come in
    /// the order the sheet is fed, so a sheet fed top edge first comes out upright (checked on an iX100 on
    /// 2026-11-29 with a sheet marked "top"). `data` holds whole RGB lines.
    public static func rgbFromSamples(_ data: [UInt8]) -> [UInt8] {
        data.map { ~$0 }
    }
}
