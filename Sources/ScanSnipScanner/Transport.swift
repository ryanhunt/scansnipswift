import ScanSnipProtocol

/// A TCP connection to one port on the scanner.
public protocol VENSStream: Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// Exactly `count` bytes. Throws `ScannerError.timedOut` or `.connectionClosed` if they do not arrive.
    func receive(exactly count: Int, timeout: Duration) async throws -> [UInt8]
    func close() async
}

/// A UDP socket aimed at one port on the scanner.
public protocol VENSDatagramSocket: Sendable {
    /// This host's IPv4 address on the route to the scanner (sent in probes and the registration).
    var localIPv4: [UInt8] { get }
    /// The local UDP port, which the scanner answers.
    var localPort: UInt16 { get }
    func send(_ bytes: [UInt8]) async throws
    /// The next datagram, or nil if none arrives within `timeout`. Throws `ScannerError.connectionClosed` once
    /// the socket is closed (by `close()` or a network error), so callers can tell that from silence.
    func receive(timeout: Duration) async throws -> [UInt8]?
    func close() async
}

/// Opens connections to one scanner. `NetworkTransport` uses Network.framework; tests use a simulated scanner.
public protocol VENSTransport: Sendable {
    func connect(port: UInt16) async throws -> any VENSStream
    func datagramSocket(port: UInt16) async throws -> any VENSDatagramSocket
}

extension VENSStream {
    /// One whole frame from the scanner, sized by its length field.
    func receiveFrame(timeout: Duration) async throws -> [UInt8] {
        let head = try await receive(exactly: 8, timeout: timeout)
        let length = try wire { () throws(VENSError) in try VENS.frameLength(header: head) }
        return head + (try await receive(exactly: length - 8, timeout: timeout))
    }
}
