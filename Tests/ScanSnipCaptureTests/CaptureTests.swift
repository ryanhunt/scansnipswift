import Testing
import ScanSnipProtocol
@testable import ScanSnipCapture

/// Captures built by hand, field by field, from the formats' documented layouts.
enum Build {
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
    static func le64(_ v: Int) -> [UInt8] { le32(v & 0xFFFF_FFFF) + le32(v >> 32) }

    /// A USBPcap packet: 27-byte header, then data.
    static func usbpcap(info: UInt8, bus: Int = 1, device: Int = 5, endpoint: UInt8, transfer: UInt8 = 3,
                        data: [UInt8] = []) -> [UInt8] {
        le16(27) + le64(0x1234) + le32(0) + le16(0x0009) + [info] + le16(bus) + le16(device) + [endpoint, transfer]
            + le32(data.count) + data
    }

    /// A Linux usbmon packet with the 64-byte (mmapped) header.
    static func usbmon(event: Character, endpoint: UInt8, device: UInt8 = 5, transfer: UInt8 = 3,
                       data: [UInt8] = []) -> [UInt8] {
        var header = le64(0x1234) + [UInt8(ascii: event.unicodeScalars.first!), transfer, endpoint, device] + le16(1)
        header += [0, 0] + le64(0) + le32(0) + le32(0) + le32(data.count) + le32(data.count)
        header += [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 0, count: 16)
        return header + data
    }

    /// A classic little-endian pcap file.
    static func pcap(linkType: Int, _ packets: [[UInt8]]) -> [UInt8] {
        var file: [UInt8] = [0xD4, 0xC3, 0xB2, 0xA1] + le16(2) + le16(4) + le32(0) + le32(0) + le32(0xFFFF) + le32(linkType)
        for packet in packets { file += le32(0) + le32(0) + le32(packet.count) + le32(packet.count) + packet }
        return file
    }

    /// A little-endian pcapng file with one interface.
    static func pcapng(linkType: Int, _ packets: [[UInt8]]) -> [UInt8] {
        var file: [UInt8] = [0x0A, 0x0D, 0x0D, 0x0A] + le32(28) + [0x4D, 0x3C, 0x2B, 0x1A] + le16(1) + le16(0)
            + [UInt8](repeating: 0xFF, count: 8) + le32(28)
        file += le32(1) + le32(20) + le16(linkType) + le16(0) + le32(0xFFFF) + le32(20)
        for packet in packets {
            let padded = packet + [UInt8](repeating: 0, count: (4 - packet.count % 4) % 4)
            let length = 32 + padded.count
            file += le32(6) + le32(length) + le32(0) + le32(0) + le32(0) + le32(packet.count) + le32(packet.count)
                + padded + le32(length)
        }
        return file
    }

    static let inquiryData = [UInt8](repeating: 0x41, count: 0x60)
    static let good = [0x53] + [UInt8](repeating: 0, count: 12)

    /// INQUIRY, then SEND DIAGNOSTIC "SETUP NET START ", as USBPcap sees them, with noise: the empty completion of
    /// each OUT, the empty submission of each IN, control transfers (one with data from the device), and another
    /// device's bulk transfer.
    static var usbpcapSession: [[UInt8]] {
        [
            usbpcap(info: 0, endpoint: 0x02, data: FujitsuUSB.commandBlock([0x12, 0, 0, 0, 0x60, 0])),
            usbpcap(info: 1, endpoint: 0x02),
            usbpcap(info: 0, endpoint: 0x80, transfer: 2, data: [0x80, 6, 0, 1, 0, 0, 0x12, 0]),
            usbpcap(info: 0, endpoint: 0x81),
            usbpcap(info: 1, endpoint: 0x81, data: inquiryData),
            usbpcap(info: 1, endpoint: 0x80, transfer: 2, data: [0x12, 0x01, 0x00, 0x02]),
            usbpcap(info: 1, device: 9, endpoint: 0x81, data: [1, 2, 3]),
            usbpcap(info: 1, endpoint: 0x81, data: good),
            usbpcap(info: 0, endpoint: 0x02, data: FujitsuUSB.commandBlock([0x1D, 0, 0, 0, 0x10, 0])),
            usbpcap(info: 0, endpoint: 0x02, data: Array("SETUP NET START ".utf8)),
            usbpcap(info: 1, endpoint: 0x81, data: good),
        ]
    }
}

@Suite struct CaptureTests {
    private let expected = [
        Transcript.Exchange(cdb: [0x12, 0, 0, 0, 0x60, 0], dataIn: Build.inquiryData, status: 0),
        Transcript.Exchange(cdb: [0x1D, 0, 0, 0, 0x10, 0], dataOut: Array("SETUP NET START ".utf8), status: 0),
    ]

    @Test func usbpcapInClassicPcap() throws {
        let transfers = try CaptureFile.bulkTransfers(in: Build.pcap(linkType: 249, Build.usbpcapSession))
        // Bulk transfers with data in the right direction: two command blocks, the diagnostic name, INQUIRY's
        // data, two status packets, and the other device's three bytes.
        #expect(transfers.count == 7)
        #expect(Transcript.exchanges(transfers) == expected)
    }

    @Test func usbpcapInPcapng() throws {
        let transfers = try CaptureFile.bulkTransfers(in: Build.pcapng(linkType: 249, Build.usbpcapSession))
        #expect(Transcript.exchanges(transfers) == expected)
    }

    @Test func linuxUsbmon() throws {
        let packets = [
            Build.usbmon(event: "S", endpoint: 0x02, data: FujitsuUSB.commandBlock([0x12, 0, 0, 0, 0x60, 0])),
            Build.usbmon(event: "C", endpoint: 0x02),
            Build.usbmon(event: "S", endpoint: 0x81),
            Build.usbmon(event: "C", endpoint: 0x81, data: Build.inquiryData),
            Build.usbmon(event: "C", endpoint: 0x81, data: Build.good),
            Build.usbmon(event: "S", endpoint: 0x02, data: FujitsuUSB.commandBlock([0x1D, 0, 0, 0, 0x10, 0])),
            Build.usbmon(event: "S", endpoint: 0x02, data: Array("SETUP NET START ".utf8)),
            Build.usbmon(event: "C", endpoint: 0x81, data: Build.good),
        ]
        let transfers = try CaptureFile.bulkTransfers(in: Build.pcap(linkType: 220, packets))
        #expect(Transcript.exchanges(transfers) == expected)
    }

    @Test func describesAnExchange() {
        #expect(Transcript.describe(expected[1]) == "SEND DIAGNOSTIC: 1d 00 00 00 10 00, \"SETUP NET START \", status 0")
        #expect(Transcript.describe(expected[0], bytesShown: 2) == "INQUIRY: 12 00 00 00 60 00, in 96: 41 41, status 0")
        #expect(expected[1].diagnosticCommand == "SETUP NET START ")
    }

    @Test func refusesOtherFiles() {
        #expect(throws: CaptureFile.Failure.notACapture) { try CaptureFile.bulkTransfers(in: [1, 2, 3, 4, 5]) }
        // Ethernet (link type 1) is not USB.
        #expect(throws: CaptureFile.Failure.unsupportedLinkType(1)) {
            try CaptureFile.bulkTransfers(in: Build.pcap(linkType: 1, [[0, 1, 2]]))
        }
        #expect(throws: CaptureFile.Failure.truncated) {
            try CaptureFile.bulkTransfers(in: Array(Build.pcap(linkType: 249, Build.usbpcapSession).dropLast(3)))
        }
    }
}
