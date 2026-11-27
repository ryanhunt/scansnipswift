import Foundation
import Network
import ScanSnipProtocol

/// Connections to a scanner at a known address, over Network.framework.
///
/// On iOS the app needs `NSLocalNetworkUsageDescription` in its Info.plist; if the user refuses local-network
/// access, connections fail with `ScannerError.network`.
public struct NetworkTransport: VENSTransport {
    /// The scanner's address, for example "192.0.2.20".
    public let host: String
    public var connectTimeout: Duration

    public init(host: String, connectTimeout: Duration = .seconds(10)) {
        self.host = host
        self.connectTimeout = connectTimeout
    }

    public func connect(port: UInt16) async throws -> any VENSStream {
        try await NetworkStream.open(host: host, port: port, timeout: connectTimeout)
    }

    public func datagramSocket(port: UInt16) async throws -> any VENSDatagramSocket {
        try await NetworkDatagramSocket.open(host: host, port: port, timeout: connectTimeout)
    }
}

/// An `NWConnection` with a start that waits for `.ready`, and a queue of its own.
final class NetworkConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "scansnip.network")

    init(host: String, port: UInt16, parameters: NWParameters) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: parameters)
    }

    /// Waits for `.ready`, up to `timeout`. `.waiting` is not final: on iOS the first local-network
    /// connection waits while the permission alert is up, and a scanner waking up can briefly have no route.
    /// The last waiting reason is reported if the timeout passes. `.failed` and `.cancelled` end the wait at
    /// once, so a cancelled connection never leaves it hanging.
    func start(timeout: Duration, onClose: @escaping @Sendable (ScannerError) -> Void) async throws {
        let once = OnceFlag()
        let lastWaiting = LockedBox<String?>(nil)
        // Cancelling the task cancels the connection, which ends the wait through `.cancelled`.
        try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case .waiting(let error):
                    lastWaiting.value = "\(error)"
                case .failed(let error):
                    if once.take() {
                        continuation.resume(throwing: ScannerError.network("\(error)"))
                    } else {
                        onClose(.network("\(error)"))
                    }
                case .cancelled:
                    if once.take() {
                        continuation.resume(throwing: ScannerError.connectionClosed("cancelled before it was ready"))
                    } else {
                        onClose(.connectionClosed("connection closed"))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [connection] in
                if once.take() {
                    connection.cancel()
                    if let reason = lastWaiting.value {
                        continuation.resume(throwing: ScannerError.network(reason))
                    } else {
                        continuation.resume(throwing: ScannerError.timedOut("connect"))
                    }
                }
            }
        }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ScannerError.network("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

final class NetworkStream: VENSStream, @unchecked Sendable {
    private let network: NetworkConnection
    private let buffer = ByteBuffer()

    private init(_ network: NetworkConnection) {
        self.network = network
    }

    deinit {
        network.connection.cancel()
    }

    static func open(host: String, port: UInt16, timeout: Duration) async throws -> NetworkStream {
        let network = NetworkConnection(host: host, port: port, parameters: .tcp)
        let stream = NetworkStream(network)
        let buffer = stream.buffer
        try await network.start(timeout: timeout) { buffer.close($0) }
        stream.receiveLoop()
        return stream
    }

    private func receiveLoop() {
        // Weak, so a stream dropped without close() is freed and its deinit cancels the connection.
        network.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { buffer.append(data) }
            if let error {
                buffer.close(.network("\(error)"))
            } else if isComplete {
                buffer.close(.connectionClosed("closed by the scanner"))
            } else {
                receiveLoop()
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await network.send(bytes)
    }

    func receive(exactly count: Int, timeout: Duration) async throws -> [UInt8] {
        try await buffer.read(count, timeout: timeout, operation: "reply")
    }

    func close() async {
        network.connection.cancel()
        buffer.close(.connectionClosed("closed"))
    }
}

final class NetworkDatagramSocket: VENSDatagramSocket, @unchecked Sendable {
    let localIPv4: [UInt8]
    let localPort: UInt16
    private let network: NetworkConnection
    private let queue = MessageQueue()

    private init(_ network: NetworkConnection, localIPv4: [UInt8], localPort: UInt16) {
        self.network = network
        self.localIPv4 = localIPv4
        self.localPort = localPort
    }

    deinit {
        network.connection.cancel()
    }

    static func open(host: String, port: UInt16, timeout: Duration) async throws -> NetworkDatagramSocket {
        let network = NetworkConnection(host: host, port: port, parameters: .udp)
        try await network.start(timeout: timeout) { _ in }
        guard case .hostPort(let localHost, let localPort)? = network.connection.currentPath?.localEndpoint,
              case .ipv4(let address) = localHost
        else {
            network.connection.cancel()
            throw ScannerError.network("no local IPv4 address on the route to \(host)")
        }
        let socket = NetworkDatagramSocket(network, localIPv4: Array(address.rawValue), localPort: localPort.rawValue)
        socket.receiveLoop()
        return socket
    }

    private func receiveLoop() {
        network.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { queue.push(Array(data)) }
            if error != nil {
                queue.close()
            } else {
                receiveLoop()
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await network.send(bytes)
    }

    func receive(timeout: Duration) async throws -> [UInt8]? {
        try await queue.next(timeout: timeout)
    }

    func close() async {
        network.connection.cancel()
        queue.close()
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
