/// Reads USB packet captures (classic pcap or pcapng) and returns their bulk transfers, for working out what an
/// app sends a scanner. Pure parsing, no I/O: pass the file's bytes.
///
/// Two link types are understood:
/// - USBPcap, Windows (`LINKTYPE_USBPCAP`, 249): a little-endian header of at least 27 bytes (header length u16,
///   IRP ID u64, status u32, function u16, info u8 with bit 0 set on the device's answer, bus u16, device u16,
///   endpoint u8 with bit 7 for IN, transfer type u8 with 3 for bulk, data length u32), then the data.
/// - Linux usbmon (`LINKTYPE_USB_LINUX`, 189, 48-byte header; `LINKTYPE_USB_LINUX_MMAPPED`, 220, 64 bytes): event
///   type at 8 (`S` submit, `C` complete), transfer type at 9 (3 for bulk), endpoint at 10, device at 11, bus u16
///   at 12, then the data after the header. Assumes a little-endian capturing machine.
///
/// A bulk OUT transfer's data is taken from the host's submission, a bulk IN transfer's from its completion.
/// Packets of other link types (another interface captured alongside) and malformed packets are skipped, and a
/// file cut off mid-packet (a capture stopped while writing) gives the packets before the cut.
public enum CaptureFile {
    public enum Failure: Error, Equatable, Sendable {
        case notACapture
        case truncated
        /// No packet in the file has a USB link type this reader understands; the first link type is given.
        case unsupportedLinkType(UInt32)
    }

    /// One bulk transfer with data, in capture order.
    public struct Transfer: Equatable, Sendable {
        /// Bus and device address, to tell devices apart.
        public let bus: Int
        public let device: Int
        /// The endpoint address; bit 7 set for IN (device to host).
        public let endpoint: UInt8
        public let data: [UInt8]

        public init(bus: Int, device: Int, endpoint: UInt8, data: [UInt8]) {
            self.bus = bus
            self.device = device
            self.endpoint = endpoint
            self.data = data
        }

        public var isIn: Bool { endpoint & 0x80 != 0 }
    }

    public static let linkTypeUSBPcap: UInt32 = 249
    public static let linkTypeUSBLinux: UInt32 = 189
    public static let linkTypeUSBLinuxMmapped: UInt32 = 220
    static let supportedLinkTypes: Set<UInt32> = [linkTypeUSBPcap, linkTypeUSBLinux, linkTypeUSBLinuxMmapped]

    /// The bulk transfers in a capture, in order. Transfers without data are left out.
    public static func bulkTransfers(in file: [UInt8]) throws(Failure) -> [Transfer] {
        let packets = try packets(in: file)
        if let first = packets.first, !packets.contains(where: { supportedLinkTypes.contains($0.0) }) {
            throw .unsupportedLinkType(first.0)
        }
        return packets.compactMap { linkType, packet in bulkTransfer(packet, linkType: linkType) }
    }

    // MARK: Containers

    /// Each packet with its link type, up to the end of the file or the first incomplete record.
    static func packets(in file: [UInt8]) throws(Failure) -> [(UInt32, [UInt8])] {
        guard file.count >= 4 else { throw .notACapture }
        let magic = Array(file[0..<4])
        if magic == [0x0A, 0x0D, 0x0D, 0x0A] { return try pcapngPackets(file) }
        let littleEndian: Bool
        switch magic {
        case [0xD4, 0xC3, 0xB2, 0xA1], [0x4D, 0x3C, 0xB2, 0xA1]: littleEndian = true
        case [0xA1, 0xB2, 0xC3, 0xD4], [0xA1, 0xB2, 0x3C, 0x4D]: littleEndian = false
        default: throw .notACapture
        }
        guard file.count >= 24 else { throw .truncated }
        let reader = Reader(file, littleEndian: littleEndian)
        let linkType = reader.u32(20)
        var packets: [(UInt32, [UInt8])] = []
        var offset = 24
        while offset + 16 <= file.count {
            let length = Int(reader.u32(offset + 8))
            let start = offset + 16
            guard start + length <= file.count else { break }
            packets.append((linkType, Array(file[start..<start + length])))
            offset = start + length
        }
        return packets
    }

    private static func pcapngPackets(_ file: [UInt8]) throws(Failure) -> [(UInt32, [UInt8])] {
        var packets: [(UInt32, [UInt8])] = []
        var interfaces: [UInt32] = []
        var reader = Reader(file, littleEndian: true)
        var offset = 0
        while offset + 12 <= file.count {
            if Array(file[offset..<offset + 4]) == [0x0A, 0x0D, 0x0D, 0x0A] {
                // Section header: the byte-order magic decides the section's byte order.
                switch Array(file[offset + 8..<offset + 12]) {
                case [0x4D, 0x3C, 0x2B, 0x1A]: reader = Reader(file, littleEndian: true)
                case [0x1A, 0x2B, 0x3C, 0x4D]: reader = Reader(file, littleEndian: false)
                default: throw offset == 0 ? .notACapture : .truncated
                }
                interfaces = []
            }
            let type = reader.u32(offset)
            let length = Int(reader.u32(offset + 4))
            guard length >= 12, length % 4 == 0, offset + length <= file.count else { break }
            switch type {
            case 1 where length >= 20:
                // Interface description: link type u16 at 8.
                interfaces.append(UInt32(reader.u16(offset + 8)))
            case 6 where length >= 32:
                // Enhanced packet: interface u32 at 8, captured length u32 at 20, data at 28, the block's length
                // repeated in its last 4 bytes.
                let interface = Int(reader.u32(offset + 8))
                let captured = Int(reader.u32(offset + 20))
                if interface < interfaces.count, 28 + captured + 4 <= length {
                    packets.append((interfaces[interface], Array(file[offset + 28..<offset + 28 + captured])))
                }
            case 3 where length >= 16:
                // Simple packet: interface 0, original length u32 at 8, data at 12 up to the snapshot length.
                let original = Int(reader.u32(offset + 8))
                let captured = min(original, length - 16)
                if !interfaces.isEmpty {
                    packets.append((interfaces[0], Array(file[offset + 12..<offset + 12 + captured])))
                }
            default:
                break
            }
            offset += length
        }
        return packets
    }

    // MARK: Link types

    /// The bulk transfer in a packet, or nil for anything else: another transfer type, the empty half of a
    /// transfer, a malformed packet, or a link type this reader does not understand.
    static func bulkTransfer(_ packet: [UInt8], linkType: UInt32) -> Transfer? {
        let reader = Reader(packet, littleEndian: true)
        switch linkType {
        case linkTypeUSBPcap:
            guard packet.count >= 27 else { return nil }
            let headerLength = Int(reader.u16(0))
            guard headerLength >= 27, headerLength <= packet.count, packet[22] == 3 else { return nil }
            let fromDevice = packet[16] & 1 != 0
            let endpoint = packet[21]
            let data = Array(packet[headerLength...])
            // OUT data rides on the submission, IN data on the completion.
            guard !data.isEmpty, fromDevice == (endpoint & 0x80 != 0) else { return nil }
            return Transfer(bus: Int(reader.u16(17)), device: Int(reader.u16(19)), endpoint: endpoint, data: data)
        case linkTypeUSBLinux, linkTypeUSBLinuxMmapped:
            let headerLength = linkType == linkTypeUSBLinux ? 48 : 64
            guard packet.count >= headerLength, packet[9] == 3 else { return nil }
            let endpoint = packet[10]
            let isIn = endpoint & 0x80 != 0
            let event = packet[8]
            guard (isIn && event == UInt8(ascii: "C")) || (!isIn && event == UInt8(ascii: "S")) else { return nil }
            let data = Array(packet[headerLength...])
            guard !data.isEmpty else { return nil }
            return Transfer(bus: Int(reader.u16(12)), device: Int(packet[11]), endpoint: endpoint, data: data)
        default:
            return nil
        }
    }
}

/// Reads unsigned integers in a fixed byte order.
struct Reader {
    let bytes: [UInt8]
    let littleEndian: Bool

    init(_ bytes: [UInt8], littleEndian: Bool) {
        self.bytes = bytes
        self.littleEndian = littleEndian
    }

    func u16(_ offset: Int) -> UInt16 {
        let (a, b) = (UInt16(bytes[offset]), UInt16(bytes[offset + 1]))
        return littleEndian ? a | b << 8 : a << 8 | b
    }

    func u32(_ offset: Int) -> UInt32 {
        let parts = (0..<4).map { UInt32(bytes[offset + $0]) }
        return littleEndian
            ? parts[0] | parts[1] << 8 | parts[2] << 16 | parts[3] << 24
            : parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
    }
}
