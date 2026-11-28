import Testing
@testable import ScanSnipUSB

@Suite struct PixelConversionTests {
    @Test func grayUsesRec601Weights() {
        // Worked by hand: red (299 * 255 + 500) / 1000 = 76; green (587 * 255 + 500) / 1000 = 150;
        // blue (114 * 255 + 500) / 1000 = 29; white (1000 * 255 + 500) / 1000 = 255; black 0.
        let rgb: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0]
        #expect(PixelConversion.gray(fromRGB: rgb) == [76, 150, 29, 255, 0])
    }

    @Test func blackAndWhitePacksDarkPixelsAsOnes() {
        // One line of 10 pixels, threshold 128: 0 black, 255 white, 127 black, 128 white, then six black.
        // Bits 1 0 1 0 1 1 1 1 | 1 1 (padded with zeros) = AF C0.
        let gray: [UInt8] = [0, 255, 127, 128, 0, 0, 0, 0, 0, 0]
        #expect(PixelConversion.blackAndWhite(fromGray: gray, width: 10) == [0xAF, 0xC0])
        // Two lines of 3: each starts a new byte.
        #expect(PixelConversion.blackAndWhite(fromGray: [0, 0, 255, 255, 255, 0], width: 3) == [0xC0, 0x20])
        #expect(PixelConversion.blackAndWhite(fromGray: [100], width: 1, threshold: 100) == [0x00])
        // Two lines of exactly 8 pixels need no padding: one byte each, black at the first and last pixel.
        let eight: [UInt8] = [0, 255, 255, 255, 255, 255, 255, 0]
        #expect(PixelConversion.blackAndWhite(fromGray: eight + eight, width: 8) == [0x81, 0x81])
    }

    @Test func bytesPerLine() {
        #expect(USBScanner.PixelFormat.rgb8.bytesPerLine(width: 10) == 30)
        #expect(USBScanner.PixelFormat.gray8.bytesPerLine(width: 10) == 10)
        #expect(USBScanner.PixelFormat.blackAndWhite1.bytesPerLine(width: 10) == 2)
    }
}
