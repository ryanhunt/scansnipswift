import ScanSnipProtocol
import ScanSnipScanner

/// What one SCSI command over USB returned.
public struct SCSIResult: Sendable, Equatable {
    /// The data read back (may be shorter than asked for).
    public let data: [UInt8]
    public let status: FujitsuUSB.StatusPacket

    public init(data: [UInt8], status: FujitsuUSB.StatusPacket) {
        self.data = data
        self.status = status
    }
}

/// Runs SCSI commands on a scanner over USB: the 31-byte command block, optional data out, data in, then the
/// 13-byte status packet. `IOUSBHostChannel` is the macOS implementation; tests use a simulated scanner.
public protocol SCSIChannel: Sendable {
    /// One command. `inputLength` is the most data to read back (0 for none).
    func run(_ cdb: [UInt8], output: [UInt8], inputLength: Int, timeout: Duration) async throws -> SCSIResult
    func close() async
}
