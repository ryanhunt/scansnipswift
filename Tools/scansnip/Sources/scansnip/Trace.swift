import Foundation
import ScanSnipProtocol
import ScanSnipScanner

/// Wraps a transport and prints every frame's shape: commands, reply sizes, statuses and the first data bytes.
/// Registration bodies (which carry the encoded password) and image data are not printed.
struct TracingTransport: VENSTransport {
    let base: any VENSTransport
    /// Where to save the data of each large scan-channel reply (image reads), if anywhere.
    let dumpDirectory: URL?
    let start = Date()

    func connect(port: UInt16) async throws -> any VENSStream {
        let stream = try await base.connect(port: port)
        trace("connect \(port)")
        return TracingStream(base: stream, port: port, start: start, dumpDirectory: dumpDirectory)
    }

    func datagramSocket(port: UInt16) async throws -> any VENSDatagramSocket {
        try await base.datagramSocket(port: port)
    }

    func trace(_ line: String) {
        print(String(format: "  [%7.2f] ", Date().timeIntervalSince(start)) + line)
    }
}

final class TracingStream: VENSStream, @unchecked Sendable {
    let base: any VENSStream
    let port: UInt16
    let start: Date
    let dumpDirectory: URL?
    private let lock = NSLock()
    private var pendingHead: [UInt8]?
    private static let counter = Counter()

    init(base: any VENSStream, port: UInt16, start: Date, dumpDirectory: URL?) {
        self.base = base
        self.port = port
        self.start = start
        self.dumpDirectory = dumpDirectory
    }

    private func trace(_ line: String) {
        print(String(format: "  [%7.2f] ", Date().timeIntervalSince(start)) + "\(port) " + line)
    }

    func send(_ bytes: [UInt8]) async throws {
        let command = bytes.count >= 12 ? UInt32(bytes[11]) : 0
        if port == VENS.scanPort, bytes.count >= 64 {
            let cdbLength = Int(bytes[35])
            let cdb = bytes[48..<(48 + cdbLength)].map { String(format: "%02x", $0) }.joined(separator: " ")
            trace("→ cdb \(cdb), \(bytes.count - 64) bytes out")
        } else {
            trace("→ control 0x\(String(command, radix: 16)), \(bytes.count) bytes")
        }
        try await base.send(bytes)
    }

    func receive(exactly count: Int, timeout: Duration) async throws -> [UInt8] {
        let bytes = try await base.receive(exactly: count, timeout: timeout)
        let head = swapHead(count == 8 ? bytes : nil)
        if count != 8, let head {
            let frame = head + bytes
            let status = frame.count >= 16
                ? UInt32(frame[12]) << 24 | UInt32(frame[13]) << 16 | UInt32(frame[14]) << 8 | UInt32(frame[15]) : 0
            let dataStart = port == VENS.scanPort ? 40 : 12
            let data = frame.count > dataStart ? Array(frame[dataStart...]) : []
            let preview = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            trace("← \(frame.count) bytes, status \(status), data \(data.count): \(preview)")
            if let dumpDirectory, port == VENS.scanPort, data.count > 1000 {
                let url = dumpDirectory.appendingPathComponent(String(format: "read-%02d.bin", Self.counter.next()))
                try? Data(data).write(to: url)
                trace("  saved \(url.lastPathComponent)")
            }
        } else if count == 8, bytes.count == 8, (UInt32(bytes[3]) | UInt32(bytes[2]) << 8) == 8 {
            trace("← 8-byte frame")
        }
        return bytes
    }

    private func swapHead(_ new: [UInt8]?) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        let old = pendingHead
        pendingHead = new
        return old
    }

    func close() async {
        await base.close()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
