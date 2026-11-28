import ScanSnipProtocol

/// Rebuilds the SCSI commands a computer sent a ScanSnap over USB from a capture's bulk transfers: each command
/// block (31 bytes starting `0x43`, sent OUT), then any data OUT and data IN, then the 13-byte status packet
/// (starting `0x53`, IN). See `FujitsuUSB`.
public enum Transcript {
    /// One command and what came with it.
    public struct Exchange: Equatable, Sendable {
        public var cdb: [UInt8]
        public var dataOut: [UInt8] = []
        public var dataIn: [UInt8] = []
        /// The SCSI status from the status packet; nil if the capture ends first.
        public var status: UInt8?

        public init(cdb: [UInt8], dataOut: [UInt8] = [], dataIn: [UInt8] = [], status: UInt8? = nil) {
            self.cdb = cdb
            self.dataOut = dataOut
            self.dataIn = dataIn
            self.status = status
        }

        /// A short name for the command, for printing.
        public var name: String {
            switch cdb.first ?? 0 {
            case 0x00: "TEST UNIT READY"
            case 0x03: "REQUEST SENSE"
            case 0x12: "INQUIRY"
            case 0x15: "MODE SELECT"
            case 0x1A: "MODE SENSE"
            case 0x1B: "SCAN"
            case 0x1C: "RECEIVE DIAGNOSTIC"
            case 0x1D: "SEND DIAGNOSTIC"
            case 0x24: "SET WINDOW"
            case 0x28: "READ"
            case 0x2A: "SEND"
            case 0x31: "OBJECT POSITION"
            case 0xC2: "HARDWARE STATUS"
            default: String(format2(cdb.first ?? 0))
            }
        }

        /// For SEND DIAGNOSTIC, the 16-character command name at the start of its data (`SETUP NET START `).
        public var diagnosticCommand: String? {
            guard cdb.first == 0x1D, dataOut.count >= 16,
                  dataOut.prefix(16).allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            return String(decoding: dataOut.prefix(16), as: UTF8.self)
        }
    }

    /// The exchanges with the device that sent command blocks (the first such device if there are several).
    ///
    /// A 13-byte IN transfer starting `0x53` is the status packet unless more IN data follows it before the
    /// next command block: after a status the host always sends the next command, so an IN transfer straight
    /// after means those 13 bytes were image data that happened to start with `0x53`.
    public static func exchanges(_ transfers: [CaptureFile.Transfer]) -> [Exchange] {
        guard let scanner = transfers.first(where: { !$0.isIn && FujitsuUSB.cdb(inCommandBlock: $0.data) != nil })
        else { return [] }
        let own = transfers.filter { $0.bus == scanner.bus && $0.device == scanner.device }
        var exchanges: [Exchange] = []
        var current: Exchange?
        for (index, transfer) in own.enumerated() {
            if !transfer.isIn, let cdb = FujitsuUSB.cdb(inCommandBlock: transfer.data) {
                if let current { exchanges.append(current) }
                current = Exchange(cdb: cdb)
            } else if transfer.isIn, current != nil, transfer.data.count == FujitsuUSB.statusPacketLength,
                      transfer.data[0] == 0x53, !(own.dropFirst(index + 1).first?.isIn ?? false),
                      let packet = FujitsuUSB.StatusPacket(transfer.data) {
                current?.status = packet.scsiStatus
                exchanges.append(current!)
                current = nil
            } else if transfer.isIn {
                current?.dataIn += transfer.data
            } else {
                current?.dataOut += transfer.data
            }
        }
        if let current { exchanges.append(current) }
        return exchanges
    }

    /// One line per exchange: name, CDB, data out (the diagnostic name if any), data in, status.
    public static func describe(_ exchange: Exchange, bytesShown: Int = 16) -> String {
        let bytesShown = max(0, bytesShown)
        var line = "\(exchange.name): \(hex(exchange.cdb))"
        if let command = exchange.diagnosticCommand {
            line += ", \"\(command)\""
            if exchange.dataOut.count > 16 { line += " + \(hex(exchange.dataOut.dropFirst(16).prefix(bytesShown)))" }
        } else if !exchange.dataOut.isEmpty {
            line += ", out \(exchange.dataOut.count): \(hex(exchange.dataOut.prefix(bytesShown)))"
        }
        if !exchange.dataIn.isEmpty { line += ", in \(exchange.dataIn.count): \(hex(exchange.dataIn.prefix(bytesShown)))" }
        line += exchange.status.map { ", status \($0)" } ?? ", no status"
        return line
    }

    static func hex(_ bytes: some Collection<UInt8>) -> String {
        bytes.map(format2).joined(separator: " ")
    }
}

private func format2(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16)
    return digits.count == 1 ? "0" + digits : digits
}
