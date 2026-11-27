import Testing
@testable import ScanSnipProtocol

/// `D4` blocks the ScanSnap iOS app sent to an iX100 (firmware 0V00) on 2026-11-27, copied from the captures.
/// They hold scan settings only, no identifiers.
private let capturedBlocks: [(VENS.IX100ScanParameters, String)] = [
    (.init(),
     "000101018001c1c1e0c8a080800000810000000000000000000000000000003000100000000005820b00000028800000"
        + "a54304000000010101000000000000000000000000000000000000000000000001100000000002820b00000028800000"
        + "a543040000000101010000000000000000000000000000000000000000000000"),
    (.init(colorMode: .color),
     "000101018001c180e0c8a080800000810000000000000000000000000000003000100000000005820b00000028800000"
        + "a543040000000101010000000000000000000000000000000000000000000000"),
    (.init(colorMode: .gray),
     "000101018001c180e0c8a080800000810000000000000000000000000000003000100000000002820b00000028800000"
        + "a543040000000101010000000000000000000000000000000000000000000000"),
    (.init(colorMode: .blackAndWhite),
     "000101018001c180e0c8a080800000810000000000000000000000000000003000400000000000030000000028800000"
        + "a543040000000101010100000600000000000000000000000000000000000000"),
    (.init(resolution: .dpi150),
     "000101018001c1c1e0c88080800000810000000000000000000000000000003000100096009605820b00000028800000"
        + "a54304000000010101000000000000000000000000000000000000000000000001100096009602820b00000028800000"
        + "a543040000000101010000000000000000000000000000000000000000000000"),
    (.init(resolution: .dpi200),
     "000101018001c1c1e0c880808000008100000000000000000000000000000030001000c800c805820b00000028800000"
        + "a543040000000101010000000000000000000000000000000000000000000000011000c800c802820b00000028800000"
        + "a543040000000101010000000000000000000000000000000000000000000000"),
    (.init(resolution: .dpi300),
     "000101018001c1c1e0c8808080000081000000000000000000000000000000300010012c012c05820b00000028800000"
        + "a5430400000001010100000000000000000000000000000000000000000000000110012c012c02820b00000028800000"
        + "a543040000000101010000000000000000000000000000000000000000000000"),
    (.init(pageSize: .a4),
     "000100008000c1c1e0c8a080800000000000000000000000000000000000003000100000000005820b00000026d00000"
        + "36d004000000010101000000000000000000000000000000000000000000000001100000000002820b00000026d00000"
        + "36d0040000000101010000000000000000000000000000000000000000000000"),
]

private func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

@Suite struct IX100Tests {
    @Test func capturedBlocksAreWellFormed() {
        for (parameters, hex) in capturedBlocks {
            #expect(bytes(hex).count == (parameters.colorMode == .automatic ? 128 : 80))
        }
    }

    @Test(arguments: capturedBlocks.indices)
    func parameterBlockMatchesTheApp(index: Int) {
        let (parameters, hex) = capturedBlocks[index]
        #expect(VENS.iX100ParameterBlock(parameters) == bytes(hex))
    }

    @Test func setParametersCommandCarriesTheLength() {
        #expect(VENS.iX100SetParametersCommand(length: 128) == [0xD4, 0, 0, 0, 0x80, 0])
        #expect(VENS.iX100SetParametersCommand(length: 80) == [0xD4, 0, 0, 0, 0x50, 0])
        #expect(VENS.iX100SetParametersCommand(length: 80) == VENS.Command.setParameters)
    }

    @Test func readCommandAsTheAppSendsIt() {
        // 28 00 00 02 00 00 04 00 00 00 <page> 00, as captured.
        #expect(VENS.readImageCommand(back: false, imageIndex: 1, length: VENS.iX100ReadLength)
            == [0x28, 0, 0, 2, 0, 0, 0x04, 0, 0, 0, 1, 0])
    }

    @Test func sheetReadyNeedsTheLoadedBit() {
        // Hardware-status replies seen on 2026-11-27: no sheet, a sheet at the slot, a sheet loaded.
        let empty: [UInt8] = [0x00, 0x00, 0x00, 0x80, 0x00, 0x01, 0x20, 0x00]
        let atTheSlot: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x20, 0x00]
        let loaded: [UInt8] = [0x00, 0x00, 0x80, 0x00, 0x00, 0x01, 0x20, 0x00]
        #expect(VENS.iX100SheetReady(empty) == false)
        #expect(VENS.iX100SheetReady(atTheSlot) == false)
        #expect(VENS.hopperHasPaper(atTheSlot) == true)  // why the iX500's rule is not enough here
        #expect(VENS.iX100SheetReady(loaded) == true)
        #expect(VENS.iX100SheetReady([0, 0]) == nil)
    }

    @Test func continuationPrefixCoversTheLeadingAppAndCommentSegments() {
        // The iX100's JPEG opening: SOI, APP0 (length 16), COM (length 21), then DQT at offset 2 + 18 + 23 = 43.
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        let comment: [UInt8] = [0xFF, 0xFE, 0x00, 0x15] + [UInt8](repeating: 0x41, count: 19)
        let image: [UInt8] = [0xFF, 0xD8] + app0 + comment + [0xFF, 0xDB, 0x00, 0x84, 0x00]
        #expect(app0.count == 18 && comment.count == 23)
        #expect(VENS.iX100ContinuationPrefixLength(image) == 43)
        #expect(VENS.iX100ContinuationPrefixLength([0xFF, 0xD8, 0xFF, 0xDB, 0, 4]) == 2)
        #expect(VENS.iX100ContinuationPrefixLength(Array("II*\u{0}".utf8)) == nil)
        // An APP0 that claims 16 bytes but is cut short: malformed, so no length (it used to give 20).
        #expect(VENS.iX100ContinuationPrefixLength([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) == nil)
    }

    @Test func onlyBlackAndWhiteReturnsTIFF() {
        #expect(VENS.IX100ScanParameters.ColorMode.allCases.filter {
            VENS.IX100ScanParameters(colorMode: $0).returnsTIFF
        } == [.blackAndWhite])
    }
}
