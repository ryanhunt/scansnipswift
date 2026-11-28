import Testing
@testable import ScanSnipProtocol

@Suite struct FujitsuUSBTests {
    @Test func commandBlockCarriesTheCDBAtOffset19() {
        // INQUIRY as sent to the iX100 on 2026-11-29: 43, 18 zeros, then 12 00 00 00 60 00, then 6 zeros.
        let block = FujitsuUSB.commandBlock([0x12, 0, 0, 0, 0x60, 0])
        #expect(block.count == 31)
        #expect(block[0] == 0x43)
        #expect(Array(block[1..<19]) == [UInt8](repeating: 0, count: 18))
        #expect(Array(block[19..<25]) == [0x12, 0, 0, 0, 0x60, 0])
        #expect(Array(block[25...]) == [UInt8](repeating: 0, count: 6))
    }

    @Test func aTwelveByteCDBFillsTheBlock() {
        let cdb: [UInt8] = [0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0C]
        #expect(FujitsuUSB.maximumCDBLength == 12)
        #expect(Array(FujitsuUSB.commandBlock(cdb)[19...]) == cdb)
    }

    @Test func statusPacket() throws {
        // As the iX100 answered: 53 then zeros (GOOD); and with 02 at byte 9 (CHECK CONDITION) for D9.
        let good = try #require(FujitsuUSB.StatusPacket([0x53] + [UInt8](repeating: 0, count: 12)))
        #expect(good.isGood && !good.isCheckCondition)
        var bytes = [0x53] + [UInt8](repeating: 0, count: 12)
        bytes[9] = 2
        let check = try #require(FujitsuUSB.StatusPacket(bytes))
        #expect(check.isCheckCondition && check.scsiStatus == 2)
        #expect(FujitsuUSB.StatusPacket([0x53, 0, 0]) == nil)
    }

    // Worked by hand for 150 dpi: 8.5 in is 1275 pixels, rounded down to even 1274 (10192 = 0x27D0 in 1/1200 in);
    // 14 in is 2100 lines (16800 = 0x41A0).
    @Test func windowAt150dpi() {
        let window = FujitsuUSB.Window(resolution: 150)
        #expect(window.widthPixels == 1274 && window.maximumLines == 2100 && window.bytesPerLine == 3822)
        // 0x40000 / 3822 = 68 whole lines = 259896 = 0x3F738 bytes, the read the iX100 answered on 2026-11-29.
        #expect(window.readLength() == 259_896)
        #expect(FujitsuUSB.Command.readImage(length: 259_896) == [0x28, 0, 0, 0, 0, 0, 0x03, 0xF7, 0x38, 0])
    }

    @Test func preReadData() {
        let data = FujitsuUSB.Window(resolution: 150).preReadData
        #expect(data.count == 32)
        #expect(String(decoding: data[0..<16], as: UTF8.self) == "SET PRE READMODE")
        #expect(Array(data[16...]) == [0x00, 0x96, 0x00, 0x96, 0x00, 0x00, 0x27, 0xD1, 0x00, 0x00, 0x41, 0xA2, 0x05,
                                       0, 0, 0])
        #expect(FujitsuUSB.Command.sendDiagnostic(length: 32) == [0x1D, 0, 0, 0, 0x20, 0])
    }

    @Test func windowData() {
        let data = FujitsuUSB.Window(resolution: 150).windowData
        #expect(data.count == 72)
        #expect(Array(data[0..<8]) == [0, 0, 0, 0, 0, 0, 0, 64])
        // The descriptor starts at 8, so its offsets are 8 more.
        #expect(Array(data[10..<14]) == [0x00, 0x96, 0x00, 0x96])
        #expect(Array(data[22..<30]) == [0x00, 0x00, 0x27, 0xD0, 0x00, 0x00, 0x41, 0xA0])
        #expect(data[33] == 5 && data[34] == 8)
        #expect(Array(data[48..<51]) == [0xC1, 0x80, 0x01])
        #expect(data[61] == 0xC0)
        #expect(Array(data[62..<70]) == [0x00, 0x00, 0x27, 0xD1, 0x00, 0x00, 0x41, 0xA2])
        #expect(data[14..<22].allSatisfy { $0 == 0 } && data[70...].allSatisfy { $0 == 0 })
        // As sent on 2026-11-29: 24 00 00 00 00 00 00 00 48 00.
        #expect(FujitsuUSB.Command.setWindow(length: 72) == [0x24, 0, 0, 0, 0, 0, 0, 0, 0x48, 0])
    }

    @Test func gammaAndModePages() {
        let gamma = FujitsuUSB.Window.linearGamma
        #expect(gamma.count == 266 && Array(gamma[0..<10]) == [0, 0, 0x10, 0, 1, 0, 1, 0, 0, 0])
        #expect(gamma[10] == 0 && gamma[265] == 255)
        #expect(FujitsuUSB.Command.sendGamma(length: 266) == [0x2A, 0, 0x83, 0, 0, 0, 0, 0x01, 0x0A, 0])
        #expect(FujitsuUSB.Window.modePages.map(\.count) == [12, 12, 14, 12])
        #expect(FujitsuUSB.Window.modePages[0] == [0, 0, 0, 0, 0x3C, 6, 0, 0x80, 0, 0, 0, 0])
        #expect(FujitsuUSB.Command.modeSelect(length: 12) == [0x15, 0x10, 0, 0, 0x0C, 0])
    }

    @Test func pixelSize() throws {
        // The iX100's answer on 2026-11-29 (first 8 of 32 bytes).
        let size = try #require(FujitsuUSB.PixelSize(data: [0, 0, 0x04, 0xFA, 0, 0, 0x08, 0x34]))
        #expect(size.width == 1274 && size.lines == 2100)
        #expect(FujitsuUSB.PixelSize(data: [0, 0, 4]) == nil)
    }

    @Test func rgbFromSamplesInvertsAndKeepsTheOrder() {
        // Two pixels: (0,0,0), which the scanner means as white, then (255,0,10). The order stays: the iX100's
        // lines come top edge first for a sheet fed top first.
        #expect(FujitsuUSB.rgbFromSamples([0, 0, 0, 255, 0, 10]) == [255, 255, 255, 0, 255, 245])
    }
}

@Suite struct CommandBlockParsingTests {
    @Test func readsTheCDBBackByItsGroup() {
        // Group 0 (INQUIRY): 6 bytes; a vendor command (C2): 10 bytes, its trailing zeros included.
        #expect(FujitsuUSB.cdb(inCommandBlock: FujitsuUSB.commandBlock([0x12, 0, 0, 0, 0x60, 0])) == [0x12, 0, 0, 0, 0x60, 0])
        #expect(FujitsuUSB.cdb(inCommandBlock: FujitsuUSB.commandBlock([0xC2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0]))
                == [0xC2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0])
        // A 12-byte group (A0–BF) fills the block.
        #expect(FujitsuUSB.cdb(inCommandBlock: FujitsuUSB.commandBlock([0xA8] + [UInt8](repeating: 1, count: 11)))?.count == 12)
    }

    @Test func otherBytesAreNotABlock() {
        var block = FujitsuUSB.commandBlock([0x00, 0, 0, 0, 0, 0])
        #expect(FujitsuUSB.cdb(inCommandBlock: Array(block.dropLast())) == nil)
        block[0] = 0x53
        #expect(FujitsuUSB.cdb(inCommandBlock: block) == nil)
    }
}
