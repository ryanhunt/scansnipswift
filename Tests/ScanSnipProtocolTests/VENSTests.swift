import Foundation
import Testing
@testable import ScanSnipProtocol

// Byte-layout checks adapted from holgerkrupp/Scan (ScanTests/VENSProtocolTests.swift, MIT), with
// documentation addresses (192.0.2.x), locally administered MACs and a made-up serial number.

private let mac: [UInt8] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
private let hostIP: [UInt8] = [192, 0, 2, 10]
private let hostID: [UInt8] = [9, 8, 7, 6, 5, 4, 3, 2]

/// A discovery reply laid out as ScanSnack documents it.
private func announcement(name: String = "iX500-A0XX012345", hostID: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]) -> [UInt8] {
    var reply = [UInt8](repeating: 0, count: 132)
    reply.replaceSubrange(0..<4, with: Array("VENS".utf8))
    reply.replaceSubrange(8..<12, with: [0, 6, 0, 0x30])
    reply.replaceSubrange(16..<20, with: [192, 0, 2, 20])
    reply.replaceSubrange(28..<34, with: [0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
    reply[39] = 4
    reply.replaceSubrange(40..<40 + name.utf8.count, with: Array(name.utf8))
    reply.replaceSubrange(104..<120, with: Array("ScanSnap iX500  ".utf8))
    reply.replaceSubrange(120..<124, with: hostIP)
    reply.replaceSubrange(124..<132, with: hostID)
    return reply
}

@Suite struct DiscoveryTests {
    @Test func probeLayout() {
        let probe = VENS.probe(hostIP: hostIP, hostMAC: mac, replyPort: 0xD7E0)
        #expect(probe.count == 32)
        #expect(Array(probe[0..<4]) == Array("VENS".utf8))
        #expect(Array(probe[4..<8]) == [0, 0, 0, 0])
        #expect(Array(probe[8..<12]) == hostIP)
        #expect(Array(probe[12..<18]) == mac)
        #expect(Array(probe[22..<26]) == [0xD7, 0xE0, 0x00, 0x10])
    }

    @Test func heartbeatProbe() {
        let probe = VENS.probe(hostIP: hostIP, hostMAC: mac, replyPort: 0, flag: VENS.heartbeatFlag, sequence: 1)
        #expect(Array(probe[4..<8]) == [0, 0, 0, 1])
        #expect(Array(probe[24..<26]) == [0x10, 0x00])
    }

    @Test func announcementParsing() throws {
        let info = try #require(VENS.Announcement(announcement()))
        #expect(info.interfaceVersion == 6)
        #expect(info.deviceType == 0x30)
        #expect(info.ipAddress == [192, 0, 2, 20])
        #expect(info.macAddress == [0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        #expect(info.state == 4)
        #expect(info.name == "iX500-A0XX012345")
        #expect(info.model == "ScanSnap iX500")
        #expect(info.serialNumber == "A0XX012345")
        #expect(info.factoryPassword == "2345")
        #expect(info.registeredHostIP == hostIP)
        #expect(info.registeredHostID == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(info.hasRegisteredHost)
        #expect(info.knownModel == .iX500)
    }

    @Test func announcementWithoutHostOrSerial() throws {
        let info = try #require(VENS.Announcement(announcement(name: "Office", hostID: [0, 0, 0, 0, 0, 0, 0, 0])))
        #expect(!info.hasRegisteredHost)
        #expect(info.serialNumber == nil)
        #expect(info.factoryPassword == nil)
    }

    @Test func rejectsShortOrForeignReplies() {
        #expect(VENS.Announcement(Array(announcement().prefix(100))) == nil)
        var iX1500 = announcement()
        iX1500.replaceSubrange(0..<4, with: Array("ssNR".utf8))
        #expect(VENS.Announcement(iX1500) == nil)
    }

    @Test func noticeParsing() throws {
        var notice = [UInt8](repeating: 0, count: 48)
        notice[3] = 0x30
        notice.replaceSubrange(4..<8, with: Array("VENS".utf8))
        notice[11] = 0x01
        notice[16] = 7
        #expect(try #require(VENS.Notice(notice)) == VENS.Notice(event: .scanButton, counter: 7))
        notice[11] = 0x10
        #expect(VENS.Notice(notice)?.event == .lidClosed)
        notice[11] = 0x21
        #expect(VENS.Notice(notice)?.event == .lidOpened)
        notice[11] = 0x55
        #expect(VENS.Notice(notice)?.event == .other(0x55))
        #expect(VENS.Notice(Array(notice.prefix(40))) == nil)
        notice[4] = 0
        #expect(VENS.Notice(notice) == nil)
    }
}

@Suite struct RegistrationTests {
    @Test func hostIDFromMAC() {
        // 0x021122334455 << 16 = 0x0211223344550000, big-endian.
        #expect(VENS.hostID(mac: mac) == [0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x00, 0x00])
    }

    @Test func passwordEncoding() throws {
        // "2345": p(112)+'2'(50)+11 = 173, F(70)+'3'(51)+11 = 132, u(117)+'4'(52)+11 = 180, s(115)+'5'(53)+11 = 179.
        #expect(String(decoding: try VENS.encodedPassword("2345"), as: UTF8.self) == "173132180179")
        #expect(try VENS.encodedPassword("").isEmpty)
        // Every key byte, worked out by hand: key[i] + '0'(48) + 11.
        let zeros = try VENS.encodedPassword(String(repeating: "0", count: 16))
        #expect(String(decoding: zeros, as: UTF8.self)
            == "171129176174126124137174137156171129164139161176")
        #expect(throws: VENSError.passwordTooLong) { try VENS.encodedPassword(String(repeating: "x", count: 17)) }
    }

    @Test func bodyOffsets() throws {
        let date = Date(timeIntervalSince1970: 1_794_000_000)  // 2026-11-06 21:20:00 UTC
        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let body = try VENS.registrationBody(
            interfaceVersion: 6, hostIP: hostIP, password: "2345", hostID: hostID, date: date, timeZone: zone)
        #expect(body.count == 96)
        #expect(Array(body[0..<4]) == [0, 6, 0x1E, 0])
        #expect(Array(body[8..<12]) == [0, 0, 0, 1])
        #expect(Array(body[12..<16]) == hostIP)
        #expect(Array(body[16..<20]) == VENS.bigEndian(UInt32(55265)))
        #expect(Array(body[20..<32]) == Array("173132180179".utf8))
        #expect(Array(body[32..<68]) == [UInt8](repeating: 0, count: 36))
        #expect(Array(body[68..<75]) == [0x07, 0xEA, 11, 6, 22, 20, 0])  // local time, UTC+1
        #expect(Array(body[76..<84]) == hostID)
        #expect(Array(body[84..<88]) == VENS.bigEndian(Int32(-3600)))
    }

    @Test func oldInterfaceHasNoTimeZone() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 36000))
        let body = try VENS.registrationBody(
            interfaceVersion: 3, hostIP: hostIP, password: "2345", hostID: hostID, date: Date(), timeZone: zone)
        #expect(Array(body[84..<88]) == [0, 0, 0, 0])
    }

    @Test func statusReply() throws {
        func reply(_ status: Int32) -> [UInt8] {
            VENS.bigEndian(UInt32(20)) + Array("VENS".utf8) + VENS.bigEndian(status) + [UInt8](repeating: 0, count: 8)
        }
        #expect(try VENS.RegistrationStatus(reply: reply(0)) == .accepted)
        #expect(try VENS.RegistrationStatus(reply: reply(-3)) == .wrongPassword)
        #expect(try VENS.RegistrationStatus(reply: reply(-4)) == .busy)
        #expect(try VENS.RegistrationStatus(reply: reply(-7)) == .unknownHost)
        #expect(try VENS.RegistrationStatus(reply: reply(-6)) == .other(-6))
        #expect(throws: VENSError.truncated(expected: 20, actual: 12)) {
            try VENS.RegistrationStatus(reply: Array(reply(0).prefix(12)))
        }
    }
}

@Suite struct FramingTests {
    @Test func clientFrameHeader() {
        let frame = VENS.clientFrame(command: 0x11, mac: mac, body: [0xAA])
        #expect(frame.count == 33)
        #expect(Array(frame[0..<4]) == [0, 0, 0, 33])
        #expect(Array(frame[4..<8]) == Array("VENS".utf8))
        #expect(Array(frame[8..<12]) == [0, 0, 0, 0x11])
        #expect(Array(frame[16..<22]) == mac)
        #expect(Array(frame[22..<32]) == [UInt8](repeating: 0, count: 10))
        #expect(frame[32] == 0xAA)
    }

    @Test func releaseFrame() {
        // Per open-scansnap: 32 bytes on 53219, command 0x12, MAC at 16.
        let frame = VENS.clientFrame(command: VENS.ControlCommand.release.rawValue, mac: mac)
        #expect(frame == [0, 0, 0, 0x20, 0x56, 0x45, 0x4E, 0x53, 0, 0, 0, 0x12, 0, 0, 0, 0]
            + [0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func scsiFrameLayout() {
        let window = VENS.windowBlock(.init())
        let frame = VENS.scsiFrame(mac: mac, cdb: VENS.Command.setPreReadMode, output: window)
        #expect(frame.count == 32 + 16 + 16 + 32)
        #expect(Array(frame[8..<12]) == [0, 0, 0, 1])
        #expect(Array(frame[32..<48]) == [0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0, 0])
        #expect(Array(frame[48..<58]) == VENS.Command.setPreReadMode)
        #expect(Array(frame[58..<64]) == [0, 0, 0, 0, 0, 0])
        #expect(Array(frame[64...]) == window)
    }

    @Test func frameLength() throws {
        #expect(try VENS.frameLength(header: [0, 0, 0, 16] + Array("VENS".utf8)) == 16)
        #expect(throws: VENSError.badMagic) { try VENS.frameLength(header: [0, 0, 0, 16] + Array("ssNR".utf8)) }
        #expect(throws: VENSError.badLength(8)) { try VENS.frameLength(header: [0, 0, 0, 8] + Array("VENS".utf8)) }
        #expect(throws: VENSError.badLength(0x7F00_0000)) {
            try VENS.frameLength(header: [0x7F, 0, 0, 0] + Array("VENS".utf8))
        }
    }

    @Test func scsiReply() throws {
        var frame = VENS.bigEndian(UInt32(43)) + Array("VENS".utf8) + [UInt8](repeating: 0, count: 32) + [1, 2, 3]
        frame[15] = 2
        let reply = try VENS.SCSIReply(frame: frame)
        #expect(reply.isCheckCondition)
        #expect(reply.data == [1, 2, 3])
        #expect(throws: VENSError.truncated(expected: 40, actual: 20)) { try VENS.SCSIReply(frame: Array(frame.prefix(20))) }
    }

    @Test func imageChunk() throws {
        let chunk = try VENS.ImageChunk(data: [3, 1, 0xFF, 0xD8], imageIndex: 3, chunk: 1)
        #expect(Array(chunk.bytes) == [0xFF, 0xD8])
        #expect(throws: VENSError.unexpectedImageChunk(expectedIndex: 2, expectedChunk: 0, actualIndex: 3, actualChunk: 0)) {
            try VENS.ImageChunk(data: [3, 0, 0xFF], imageIndex: 2, chunk: 0)
        }
    }
}

@Suite struct ScanCommandTests {
    @Test func readCommandsForFrontAndBack() {
        #expect(VENS.readImageCommand(back: false, imageIndex: 2) == [0x28, 0, 0, 2, 0, 0, 0x30, 0, 0, 0, 2, 0])
        #expect(VENS.readImageCommand(back: true, imageIndex: 3) == [0x28, 0, 0, 2, 0, 0x80, 0x30, 0, 0, 0, 3, 0])
        #expect(VENS.imageInfoCommand(imageIndex: 3) == [0x28, 0, 0x80, 0, 0, 0x80, 0, 0, 0x20, 0, 3, 0])
        #expect(VENS.readImageCommand(back: false, imageIndex: 256)[10] == 0)
    }

    @Test func windowBlock() {
        let block = VENS.windowBlock(.init(resolution: 600, pageSize: .a4))
        #expect(block.count == 32)
        #expect(Array(block[0..<13]) == [0x02, 0x58, 0x02, 0x58, 0, 0, 0x26, 0xC1, 0, 0, 0x36, 0xD0, 0x05])
    }

    /// The colour / 300 dpi / automatic block, byte for byte as ScanSnack's table documents it.
    @Test func parameterBlockMatchesScanSnapHome() {
        let block = VENS.parameterBlock(.init(resolution: 300, pageSize: .automatic, detectsDoubleFeed: true))
        var expected = [UInt8](repeating: 0, count: 80)
        expected[1] = 3
        expected[2] = 1
        expected[3] = 1
        expected[4] = 0xD0
        expected[6] = 0xC1
        for index in [7, 8, 9, 11, 12] { expected[index] = 0x80 }
        expected[10] = 0x90
        expected[31] = 0x30
        expected.replaceSubrange(32..<41, with: [0x00, 0x10, 0x01, 0x2C, 0x01, 0x2C, 5, 0x81, 0])
        expected.replaceSubrange(42..<51, with: [0, 0, 0x28, 0xD0, 0, 0, 0x44, 0xDC, 4])
        #expect(block == expected)
    }

    @Test func parameterBlockVariants() {
        let fixed = VENS.parameterBlock(.init(resolution: 600, pageSize: .letter, detectsDoubleFeed: false))
        #expect(Array(fixed[2...4]) == [0, 0, 0])
        #expect(fixed[10] == 0x80)
        #expect(fixed[13] == 0x80)
        #expect(fixed[40] == 0x0A)
        #expect(Array(fixed[42..<50]) == [0, 0, 0x27, 0xD8, 0, 0, 0x33, 0x90])
        #expect(VENS.parameterBlock(.init(resolution: 150))[40] == 5)
        #expect(!VENS.ScanParameters(resolution: 400).isValid)
    }

    @Test func hopperSensor() {
        #expect(VENS.hopperHasPaper([0, 0, 0, 0x00]) == true)
        #expect(VENS.hopperHasPaper([0, 0, 0, 0x80]) == false)
        #expect(VENS.hopperHasPaper([0, 0]) == nil)
    }
}
