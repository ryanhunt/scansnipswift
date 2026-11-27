extension VENS {
    /// Bytes the ScanSnap iOS app asks for per image read on the iX100. One read has held a whole page so far
    /// (up to 192 KB at 300 dpi grey); the reply ends with CHECK CONDITION and an end-of-medium sense.
    public static let iX100ReadLength = 0x4_0000

    /// What an iX100 scan asks for: the settings the ScanSnap iOS app offers. Unlike the iX500, the iX100
    /// can pick the colour mode and resolution itself and crops the page on the scanner.
    ///
    /// Captured from the app on 2026-11-27 (firmware 0V00): automatic everything; colour, grey and
    /// black-and-white with automatic resolution; 150, 200 and 300 dpi with automatic colour; A4 with
    /// automatic colour and resolution. Other combinations are built from the same fields but have not been
    /// scanned yet. See docs/PROTOCOL-iX100-WiFi.md.
    public struct IX100ScanParameters: Sendable, Hashable {
        public enum ColorMode: Sendable, Hashable, CaseIterable {
            /// The scanner chooses colour or grey per page (two windows in the block).
            case automatic
            /// A colour JPEG.
            case color
            /// A one-component JPEG.
            case gray
            /// A 1-bit TIFF, CCITT Group 4, white is zero. 400 dpi with automatic resolution.
            case blackAndWhite
        }

        /// The app's image quality: automatic (200 dpi was chosen for a text page), Normal, Better and Best.
        /// The app offers no 600 dpi for the iX100.
        public enum Resolution: Sendable, Hashable, CaseIterable {
            case automatic, dpi150, dpi200, dpi300

            var dpi: UInt16 {
                switch self {
                case .automatic: 0
                case .dpi150: 150
                case .dpi200: 200
                case .dpi300: 300
                }
            }
        }

        /// Paper sizes seen so far, in 1/1200 inch. The iX100's A4 width (0x26D0) differs from the iX500's.
        public enum PageSize: Sendable, Hashable, CaseIterable {
            /// Detect and crop the page on the scanner.
            case automatic
            case a4

            public var size: (width: UInt32, height: UInt32) {
                switch self {
                case .automatic: (0x2880, 0xA543)
                case .a4: (0x26D0, 0x36D0)
                }
            }
        }

        public var colorMode: ColorMode
        public var resolution: Resolution
        public var pageSize: PageSize

        public init(colorMode: ColorMode = .automatic, resolution: Resolution = .automatic,
                    pageSize: PageSize = .automatic) {
            self.colorMode = colorMode
            self.resolution = resolution
            self.pageSize = pageSize
        }

        /// Whether pages come back as TIFF (black and white) rather than JPEG.
        public var returnsTIFF: Bool { colorMode == .blackAndWhite }
    }

    /// `setParameters` (`D4`) data for the iX100: 32 bytes of scan parameters, then one 48-byte window
    /// descriptor, or two (colour and grey) when the colour mode is automatic. Send it with
    /// `Command.setParameters` changed to the block's length (`iX100SetParametersCommand`).
    ///
    /// | Offset | Meaning |
    /// |---|---|
    /// | 1 | 1 |
    /// | 2, 3, 5 | 1 for automatic page size, else 0 |
    /// | 4, 6 | 0x80, 0xC1 |
    /// | 7 | 0xC1 for automatic colour, else 0x80 |
    /// | 8, 9 | 0xE0, 0xC8 |
    /// | 10 | 0xA0 for automatic resolution, else 0x80 |
    /// | 11, 12 | 0x80 |
    /// | 15 | 0x81 for automatic page size, else 0 |
    /// | 31 | 0x30 |
    ///
    /// Window descriptor: window ID, 0x10 (JPEG) or 0x40 (black and white), u16 dpi x and y (0 for
    /// automatic), composition (5 colour, 2 grey, 0 black and white), 0x82 (JPEG) or 0x03, JPEG quality 0x0B
    /// (or 0), 0, u32 width, u32 height, 4, then `01 01 01` at 22; black and white adds 1 at 25 and 6 at 28.
    public static func iX100ParameterBlock(_ parameters: IX100ScanParameters) -> [UInt8] {
        let automaticSize: UInt8 = parameters.pageSize == .automatic ? 1 : 0
        var block = [UInt8](repeating: 0, count: 32)
        block[1] = 1
        block[2] = automaticSize
        block[3] = automaticSize
        block[4] = 0x80
        block[5] = automaticSize
        block[6] = 0xC1
        block[7] = parameters.colorMode == .automatic ? 0xC1 : 0x80
        block[8] = 0xE0
        block[9] = 0xC8
        block[10] = parameters.resolution == .automatic ? 0xA0 : 0x80
        block[11] = 0x80
        block[12] = 0x80
        block[15] = automaticSize == 1 ? 0x81 : 0
        block[31] = 0x30

        func window(id: UInt8, composition: UInt8) -> [UInt8] {
            let blackAndWhite = composition == 0
            let dpi = parameters.resolution.dpi
            let size = parameters.pageSize.size
            var descriptor: [UInt8] = [id, blackAndWhite ? 0x40 : 0x10] + bigEndian(dpi) + bigEndian(dpi)
            descriptor += [composition, blackAndWhite ? 0x03 : 0x82, blackAndWhite ? 0 : 0x0B, 0]
            descriptor += bigEndian(size.width) + bigEndian(size.height) + [4, 0, 0, 0, 1, 1, 1]
            descriptor += [UInt8](repeating: 0, count: 48 - descriptor.count)
            if blackAndWhite {
                descriptor[25] = 1
                descriptor[28] = 6
            }
            return descriptor
        }

        switch parameters.colorMode {
        case .automatic: return block + window(id: 0, composition: 5) + window(id: 1, composition: 2)
        case .color: return block + window(id: 0, composition: 5)
        case .gray: return block + window(id: 0, composition: 2)
        case .blackAndWhite: return block + window(id: 0, composition: 0)
        }
    }

    /// The `D4` command for an iX100 parameter block of `length` bytes (80 or 128).
    public static func iX100SetParametersCommand(length: Int) -> [UInt8] {
        [0xD4, 0, 0, 0, UInt8(length & 0xFF), 0]
    }
}
