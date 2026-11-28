/// Grey and black-and-white pages made on the computer from the scanner's colour lines, as holgerkrupp/Scan does
/// for the iX500, which always scans in colour. Pure functions.
public enum PixelConversion {
    /// 8-bit grey from 8-bit RGB: luma with the Rec. 601 weights, rounded, `(299 R + 587 G + 114 B + 500) / 1000`.
    public static func gray(fromRGB rgb: [UInt8]) -> [UInt8] {
        precondition(rgb.count % 3 == 0, "RGB data is whole pixels")
        var gray = [UInt8](repeating: 0, count: rgb.count / 3)
        rgb.withUnsafeBufferPointer { source in
            for pixel in gray.indices {
                let r = Int(source[pixel * 3]), g = Int(source[pixel * 3 + 1]), b = Int(source[pixel * 3 + 2])
                gray[pixel] = UInt8((299 * r + 587 * g + 114 * b + 500) / 1000)
            }
        }
        return gray
    }

    /// One bit per pixel from 8-bit grey: a pixel darker than `threshold` is black. Bits run from the most
    /// significant, 1 is black (as in fax and TIFF Group 4), and each line is padded to whole bytes.
    public static func blackAndWhite(fromGray gray: [UInt8], width: Int, threshold: UInt8 = 128) -> [UInt8] {
        precondition(width > 0 && gray.count % width == 0, "Grey data is whole lines")
        let lines = gray.count / width
        let bytesPerLine = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerLine * lines)
        for line in 0..<lines {
            for x in 0..<width where gray[line * width + x] < threshold {
                bits[line * bytesPerLine + x / 8] |= 0x80 >> UInt8(x % 8)
            }
        }
        return bits
    }
}
