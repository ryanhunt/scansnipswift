import Testing
@testable import ScanSnipProtocol

@Suite struct SenseTests {
    private func sense(key: UInt8, code: UInt8 = 0, qualifier: UInt8 = 0, flags: UInt8 = 0) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 18)
        data[0] = 0x70
        data[2] = flags | key
        data[12] = code
        data[13] = qualifier
        return data
    }

    @Test func endOfImageFromIX100() throws {
        // REQUEST SENSE after an iX100 image read over Wi-Fi: no sense key, end of medium and incorrect
        // length, and the information field holds the residual: 0x40000 asked - 77,693 sent = 0x2D083.
        let data: [UInt8] = [0xF0, 0x00, 0x60, 0x00, 0x02, 0xD0, 0x83, 0x0A] + [UInt8](repeating: 0, count: 10)
        let sense = try #require(SCSISense(data))
        #expect(sense.key == 0)
        #expect(sense.endOfMedium && sense.incorrectLength)
        #expect(sense.information == 0x2D083)
        #expect(sense.paperProblem == nil)
    }

    @Test func paperProblems() throws {
        #expect(try #require(SCSISense(sense(key: 3, code: 0x80, qualifier: 0x03))).paperProblem == .feederEmpty)
        #expect(try #require(SCSISense(sense(key: 3, code: 0x80, qualifier: 0x01))).paperProblem == .jam)
        #expect(try #require(SCSISense(sense(key: 3, code: 0x80, qualifier: 0x07))).paperProblem == .doubleFeed)
        #expect(try #require(SCSISense(sense(key: 3, code: 0x80, qualifier: 0x33))).paperProblem == .heldByCloudOrMobile)
        #expect(try #require(SCSISense(sense(key: 3, code: 0x80, qualifier: 0x09))).paperProblem == .other(9))
        #expect(try #require(SCSISense(sense(key: 5, code: 0x20))).paperProblem == nil)
        #expect(try #require(SCSISense(sense(key: 5, code: 0x20))).description == "sense 05/20/00")
    }

    @Test func endOfImage() throws {
        var data = sense(key: 0, flags: 0x40 | 0x20)
        data.replaceSubrange(3..<7, with: [0, 0, 0x01, 0x00])
        let end = try #require(SCSISense(data))
        #expect(end.endOfMedium)
        #expect(end.incorrectLength)
        #expect(end.information == 256)
        #expect(end.paperProblem == nil)
        #expect(SCSISense(Array(data.prefix(10))) == nil)
    }
}

@Suite struct ModelTests {
    @Test func usbLookup() {
        #expect(ScanSnapModel.matching(usbVendorID: 0x04C5, productID: 0x132B) == .iX500)
        #expect(ScanSnapModel.matching(usbVendorID: 0x04C5, productID: 0x13F3) == .iX500)
        #expect(ScanSnapModel.matching(usbVendorID: 0x04C5, productID: 0x13F4) == .iX100)
        #expect(ScanSnapModel.matching(usbVendorID: 0x04C5, productID: 0x1234) == nil)
        #expect(ScanSnapModel.matching(usbVendorID: 0x04B8, productID: 0x132B) == nil)
    }

    @Test func announcedModelLookup() {
        #expect(ScanSnapModel.matching(announcedModel: "ScanSnap iX500  ") == .iX500)
        #expect(ScanSnapModel.matching(announcedModel: "ScanSnap iX100") == .iX100)
        #expect(ScanSnapModel.matching(announcedModel: "ScanSnap iX1500") == nil)
        #expect(ScanSnapModel.matching(announcedModel: "iX500") == nil)
    }

    @Test func capabilities() {
        #expect(ScanSnapModel.iX500.duplex && ScanSnapModel.iX500.sheetFeeder)
        #expect(!ScanSnapModel.iX100.duplex && !ScanSnapModel.iX100.sheetFeeder)
        #expect(ScanSnapModel.iX500.wiFi == .vens)
        #expect(ScanSnapModel.iX100.wiFi == .vens)
        // ScanSnap Manager's help: the iX500's roller set every 200,000 sheets; the iX100 has no consumables.
        #expect(ScanSnapModel.iX500.rollerSetReplacementSheets == 200_000)
        #expect(ScanSnapModel.iX100.rollerSetReplacementSheets == nil)
    }
}
