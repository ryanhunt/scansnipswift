import Testing
@testable import ScanSnipProtocol

@Suite struct InfoTests {
    /// A control-channel reply: 16-byte header (length 32, VENS), then the given bytes.
    private func statusReply(_ body: [UInt8]) -> [UInt8] {
        VENS.bigEndian(UInt32(16 + body.count)) + VENS.magic + [0, 0, 0, 0, 0, 0, 0, 0] + body
    }

    @Test func statusWithBatteryAsTheIX100SendsIt() throws {
        // Seen on 28 Nov 2026: word 3, then 02 00 80 64 (100%).
        let full = try #require(VENS.ControlStatus(reply: statusReply([0, 0, 0, 3, 0x02, 0, 0x80, 0x64] + Array(repeating: 0, count: 8))))
        #expect(full == VENS.ControlStatus(word: 3, batteryPercent: 100, batteryLow: false))
        // Seen at the end of an evening on battery: 02 00 c0 06 (6%, low).
        let low = try #require(VENS.ControlStatus(reply: statusReply([0, 0, 0, 3, 0x02, 0, 0xC0, 0x06] + Array(repeating: 0, count: 8))))
        #expect(low.batteryPercent == 6 && low.batteryLow)
        // Right after power-on the word was 2.
        #expect(VENS.ControlStatus(reply: statusReply([0, 0, 0, 2, 0x02, 0, 0x80, 0x3B]))?.word == 2)
    }

    @Test func statusWithoutBattery() throws {
        // The iX500, per ScanSnack, sends only the status word.
        let status = try #require(VENS.ControlStatus(reply: statusReply([0, 0, 0, 3])))
        #expect(status.batteryPercent == nil && !status.batteryLow && status.word == 3)
        #expect(VENS.ControlStatus(reply: statusReply([0, 0])) == nil)
        // A level over 100 is not a percentage.
        #expect(VENS.ControlStatus(reply: statusReply([0, 0, 0, 3, 0x02, 0, 0x80, 0xFF]))?.batteryPercent == nil)
    }

    @Test func pageCounters() throws {
        // 0xCE = 206 three times, as an iX100 answered; then padding to 0x20 bytes.
        let data: [UInt8] = [0, 0, 0, 0xCE, 0, 0, 0, 0xCE, 0, 0, 0, 0xCE] + Array(repeating: 0, count: 20)
        let counters = try #require(VENS.PageCounters(data: data))
        #expect(counters.pages == 206)
        #expect(counters.others == [206, 206])
        #expect(VENS.PageCounters(data: [0, 0, 1, 0])?.pages == 256)
        #expect(VENS.PageCounters(data: [0, 0, 1, 0])?.others == [])
        #expect(VENS.PageCounters(data: [1, 2]) == nil)
    }

    @Test func inquiry() throws {
        var data = [UInt8](repeating: 0, count: 96)
        data[0] = 0x06
        data.replaceSubrange(8..<16, with: Array("FUJITSU ".utf8))
        data.replaceSubrange(16..<32, with: Array("ScanSnap iX100  ".utf8))
        data.replaceSubrange(32..<36, with: Array("0V00".utf8))
        let inquiry = try #require(VENS.Inquiry(data: data))
        #expect(inquiry.vendor == "FUJITSU" && inquiry.product == "ScanSnap iX100" && inquiry.revision == "0V00")
        #expect(VENS.Inquiry(data: Array(data.prefix(30))) == nil)
    }
}
