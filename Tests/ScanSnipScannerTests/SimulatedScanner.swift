import Foundation
import ScanSnipProtocol
@testable import ScanSnipScanner

/// An in-memory iX100 that behaves as the real one did on 2026-11-27: a greeting on every connection,
/// control commands only after registering, mobile registration with the factory password, a new sheet
/// touching the slot for a few reads before it is loaded, blank sheets (an empty sheet image) read back with no image, and a
/// release mid-job leaving it busy until reset. A sheet fed before it is loaded scans nothing here; the real
/// iX100's read then did not answer within 15 s.
actor SimulatedScanner {
    /// What the client did, in order: "register", "status", "release", SCSI opcodes as "D8", "D4(128)",
    /// "28#0" (read page 0) and so on. Hardware-status polls are counted, not listed.
    private(set) var events: [String] = []
    private(set) var statusPolls = 0
    private(set) var scanConnections = 0
    private(set) var datagramSockets = 0
    private(set) var heartbeats = 0
    private(set) var registeredMAC: [UInt8]?
    private(set) var jobOpen = false
    /// Set by a release while a job is open: every later registration gets -4, as on the real iX100.
    private(set) var stuck = false

    var model = "ScanSnap iX100"
    var batteryPercent: UInt8 = 0x64
    var pagesScanned: UInt32 = 206
    var serial = "A0XX012345"
    var password = "2345"
    /// Does not answer discovery (switched off, or not at this address).
    var silent = false
    /// Sheets the user will put in, one after another.
    var sheets: [[UInt8]] = []
    /// Close the scan connection instead of answering this page's read.
    var failReadOfPage: Int?
    /// Answer reads only after this many later commands have arrived (a late reply, as on hardware).
    var lateReads = false
    /// Close the status request's connection without answering (a failure right after registering).
    var dropStatus = false
    /// Answer end-of-job with CHECK CONDITION, as if the job could not be ended.
    var failEndJob = false
    /// Close each datagram socket from the scanner's side after this many heartbeats on it.
    var closeSocketsAfterHeartbeats: Int?
    private var lateReply: (() -> Void)?

    /// Reads left while the next sheet touches the slot but is not loaded yet.
    private var touchingReads = 3
    private var currentImage: [UInt8] = []
    /// What is left of the current image to send, as the iX100 splits pages larger than one read.
    private var pendingImage: [UInt8] = []
    private var continuing = false
    private var lastSense = [UInt8](repeating: 0, count: 18)

    init(sheets: [[UInt8]] = []) {
        self.sheets = sheets
    }

    func setModel(_ model: String) {
        self.model = model
    }

    func setSerial(_ serial: String) {
        self.serial = serial
    }

    func setSilent(_ silent: Bool) {
        self.silent = silent
    }

    func setFailReadOfPage(_ page: Int?) {
        failReadOfPage = page
    }

    func setLateReads(_ late: Bool) {
        lateReads = late
    }

    /// Answers a read held back by `lateReads` now.
    func releaseLateReply() {
        if let late = lateReply {
            lateReply = nil
            late()
        }
    }

    func setBattery(_ percent: UInt8) {
        batteryPercent = percent
    }

    func setDropStatus(_ drop: Bool) {
        dropStatus = drop
    }

    func setFailEndJob(_ fail: Bool) {
        failEndJob = fail
    }

    func setCloseSocketsAfterHeartbeats(_ count: Int?) {
        closeSocketsAfterHeartbeats = count
    }

    func openedDatagramSocket() {
        datagramSockets += 1
    }

    // MARK: Connections

    func accept(_ stream: SimulatedStream) {
        if stream.port == VENS.scanPort { scanConnections += 1 }
        stream.inbound.append(VENS.bigEndian(UInt32(16)) + VENS.magic + [UInt8](repeating: 0, count: 8))
    }

    func handle(_ frame: [UInt8], from stream: SimulatedStream) {
        let command = UInt32(frame[8]) << 24 | UInt32(frame[9]) << 16 | UInt32(frame[10]) << 8 | UInt32(frame[11])
        let mac = Array(frame[16..<22])
        if stream.port == VENS.controlPort {
            control(command, mac: mac, body: Array(frame[32...]), stream: stream)
        } else if mac != registeredMAC {
            stream.closeFromScanner()
        } else {
            scsi(frame, stream: stream)
        }
    }

    private func control(_ command: UInt32, mac: [UInt8], body: [UInt8], stream: SimulatedStream) {
        switch command {
        case VENS.ControlCommand.register.rawValue:
            events.append("register")
            let reserveMode = body.count >= 8 ? body[7] : 0
            let expected = (try? VENS.encodedPassword(password)) ?? []
            let status: Int32
            if stuck || (registeredMAC != nil && registeredMAC != mac) {
                status = -4
            } else if reserveMode != 1 {
                status = -6
            } else if Array(body[20..<(20 + expected.count)]) != expected || body[20 + expected.count] != 0 {
                status = -3
            } else {
                registeredMAC = mac
                status = 0
            }
            stream.inbound.append(VENS.bigEndian(UInt32(20)) + VENS.magic + VENS.bigEndian(status)
                                  + [0, 6, 0, 0, 0, 0, 0, 0])
        case _ where mac != registeredMAC:
            stream.closeFromScanner()
        case VENS.ControlCommand.release.rawValue:
            events.append("release")
            if jobOpen { stuck = true }
            registeredMAC = nil
            stream.inbound.append(VENS.bigEndian(UInt32(16)) + VENS.magic + [UInt8](repeating: 0, count: 8))
        case VENS.ControlCommand.status.rawValue:
            events.append("status")
            if dropStatus { return stream.closeFromScanner() }
            stream.inbound.append(VENS.bigEndian(UInt32(32)) + VENS.magic + [UInt8](repeating: 0, count: 8)
                                  + [0, 0, 0, 3, 2, 0, batteryPercent < 10 ? 0xC0 : 0x80, batteryPercent]
                                  + [UInt8](repeating: 0, count: 8))
        default:
            stream.closeFromScanner()
        }
    }

    private func scsi(_ frame: [UInt8], stream: SimulatedStream) {
        // A read held back by `lateReads` is answered when the next command arrives, ahead of that
        // command's own reply, as the real iX100 did after a 70 s read.
        if let late = lateReply {
            lateReply = nil
            late()
        }
        let cdbLength = Int(frame[35])
        let cdb = Array(frame[48..<(48 + cdbLength)])
        let output = Array(frame[64...])
        func reply(_ status: UInt32, _ data: [UInt8] = []) {
            let header = VENS.bigEndian(UInt32(40 + data.count)) + VENS.magic + [0, 0, 0, 0] + VENS.bigEndian(status)
            stream.inbound.append(header + [UInt8](repeating: 0, count: 24) + data)
        }
        func checkCondition(key: UInt8, code: UInt8, qualifier: UInt8) {
            var sense = [UInt8](repeating: 0, count: 18)
            sense[0] = 0xF0
            sense[2] = key
            sense[12] = code
            sense[13] = qualifier
            lastSense = sense
            reply(2)
        }
        switch cdb[0] {
        case 0xD8:
            events.append("D8")
            reply(0)
        case 0xD4:
            events.append("D4(\(output.count))")
            reply(0)
        case 0xD5:
            events.append("D5")
            jobOpen = true
            reply(0, [UInt8](repeating: 0, count: 8))
        case 0xC2:
            statusPolls += 1
            var status = [UInt8](repeating: 0, count: 32)
            switch sensor() {
            case .empty: status[3] = 0x80
            case .touching: break
            case .loaded: status[2] = 0x80
            }
            reply(0, status)
        case 0xE0:
            events.append("E0")
            guard !sheets.isEmpty else { return checkCondition(key: 3, code: 0x80, qualifier: 3) }
            // Fed before it was loaded, the real iX100 scanned nothing.
            currentImage = touchingReads > 0 ? [] : sheets.first!
            pendingImage = currentImage
            continuing = false
            sheets.removeFirst()
            touchingReads = 3
            reply(0)
        case 0x28:
            let page = Int(cdb[10])
            events.append("28#\(page)")
            if page == failReadOfPage {
                stream.closeFromScanner()
                return
            }
            // A read carries the chunk header, then (after the first) two bytes and a copy of the image's
            // leading segments, then as much of the image as fits; GOOD if more is left, else end of medium.
            let length = Int(cdb[6]) << 16 | Int(cdb[7]) << 8 | Int(cdb[8])
            var data: [UInt8] = [UInt8(page & 0xFF), 0]
            if continuing {
                // Worked out here, not with the client's own helper, so the test can catch a wrong helper.
                data += [0x13, 0x8F] + currentImage[2..<Self.leadingSegmentsEnd(currentImage)]
            }
            let take = min(pendingImage.count, length - data.count)
            data += pendingImage.prefix(take)
            pendingImage.removeFirst(take)
            continuing = true
            guard pendingImage.isEmpty else { return reply(0, data) }
            var sense = [UInt8](repeating: 0, count: 18)
            sense[0] = 0xF0
            sense[2] = 0x60  // end of medium, incorrect length
            lastSense = sense
            if lateReads {
                lateReply = { reply(2, data) }
            } else {
                reply(2, data)
            }
        case 0x03:
            events.append("03")
            reply(0, lastSense)
        case 0x12:
            events.append("INQUIRY")
            var data = [UInt8](repeating: 0x20, count: 96)
            data.replaceSubrange(0..<8, with: [0x06, 0, 0x02, 0x02, 0x5B, 0, 0, 0x10])
            data.replaceSubrange(8..<16, with: Array("FUJITSU ".utf8))
            let product = Array((model + "                ").utf8.prefix(16))
            data.replaceSubrange(16..<32, with: product)
            data.replaceSubrange(32..<36, with: Array("0V00".utf8))
            reply(0, data)
        case 0xD9:
            events.append("D9")
            let count = VENS.bigEndian(pagesScanned)
            reply(0, count + count + count + [UInt8](repeating: 0, count: 20))
        case 0xD6:
            events.append("D6")
            if failEndJob { return checkCondition(key: 5, code: 0x2C, qualifier: 0) }
            jobOpen = false
            reply(0)
        default:
            events.append(String(format: "%02X?", cdb[0]))
            checkCondition(key: 5, code: 0x20, qualifier: 0)
        }
    }

    /// Where the JPEG's leading APPn and comment segments end (43 for the iX100's pages).
    static func leadingSegmentsEnd(_ jpeg: [UInt8]) -> Int {
        var offset = 2
        while offset + 4 <= jpeg.count, jpeg[offset] == 0xFF, jpeg[offset + 1] >= 0xE0, jpeg[offset + 1] != 0xFF,
              jpeg[offset + 1] <= 0xEF || jpeg[offset + 1] == 0xFE {
            offset += 2 + Int(jpeg[offset + 2]) * 256 + Int(jpeg[offset + 3])
        }
        return offset
    }

    enum Sensor { case empty, touching, loaded }

    /// No sheet reads empty; the next sheet then touches the slot for three reads before it is loaded.
    private func sensor() -> Sensor {
        guard !sheets.isEmpty else { return .empty }
        if touchingReads > 0 {
            touchingReads -= 1
            return .touching
        }
        return .loaded
    }

    // MARK: Datagrams

    func datagram(_ bytes: [UInt8], from socket: SimulatedDatagramSocket) {
        guard bytes.count == 32, Array(bytes[0..<4]) == VENS.magic else { return }
        let flag = UInt16(bytes[24]) << 8 | UInt16(bytes[25])
        if flag == VENS.discoveryFlag {
            guard !silent else { return }
            socket.queue.push(announcement())
        } else if flag == VENS.heartbeatFlag {
            heartbeats += 1
            socket.heartbeats += 1
            socket.queue.push(VENS.magic + [0x80, 0x01, 0, 0, 0, 0, 0, 0])
            if let limit = closeSocketsAfterHeartbeats, socket.heartbeats >= limit { socket.queue.close() }
        }
    }

    func announcement() -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 132)
        reply.replaceSubrange(0..<4, with: VENS.magic)
        reply.replaceSubrange(8..<12, with: [0, 6, 0, 0x30])
        reply.replaceSubrange(16..<20, with: [192, 0, 2, 20])
        reply.replaceSubrange(28..<34, with: [0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        let name = Array("\(model.split(separator: " ").last ?? "")-\(serial)".utf8)
        reply.replaceSubrange(40..<(40 + name.count), with: name)
        let modelBytes = Array(model.utf8)
        reply.replaceSubrange(104..<(104 + modelBytes.count), with: modelBytes)
        reply.replaceSubrange(124..<132, with: [UInt8](repeating: 0xFF, count: 8))
        return reply
    }
}

struct SimulatedTransport: VENSTransport {
    let scanner: SimulatedScanner

    func connect(port: UInt16) async throws -> any VENSStream {
        let stream = SimulatedStream(port: port, scanner: scanner)
        await scanner.accept(stream)
        return stream
    }

    func datagramSocket(port: UInt16) async throws -> any VENSDatagramSocket {
        await scanner.openedDatagramSocket()
        return SimulatedDatagramSocket(scanner: scanner)
    }
}

final class SimulatedStream: VENSStream, @unchecked Sendable {
    let port: UInt16
    let scanner: SimulatedScanner
    let inbound = ByteBuffer()
    private let lock = NSLock()
    private var outbound: [UInt8] = []
    private var closed = false

    init(port: UInt16, scanner: SimulatedScanner) {
        self.port = port
        self.scanner = scanner
    }

    func send(_ bytes: [UInt8]) async throws {
        // Like a cancelled NWConnection, a closed stream sends nothing.
        guard let frames = takeFrames(adding: bytes) else { throw ScannerError.connectionClosed("closed") }
        for frame in frames {
            await scanner.handle(frame, from: self)
        }
    }

    private func takeFrames(adding bytes: [UInt8]) -> [[UInt8]]? {
        lock.lock()
        defer { lock.unlock() }
        if closed { return nil }
        outbound += bytes
        var frames: [[UInt8]] = []
        while outbound.count >= 4 {
            let length = Int(outbound[0]) << 24 | Int(outbound[1]) << 16 | Int(outbound[2]) << 8 | Int(outbound[3])
            guard outbound.count >= length else { break }
            frames.append(Array(outbound.prefix(length)))
            outbound.removeFirst(length)
        }
        return frames
    }

    func receive(exactly count: Int, timeout: Duration) async throws -> [UInt8] {
        try await inbound.read(count, timeout: timeout, operation: "reply")
    }

    func close() async {
        markClosed()
        inbound.close(.connectionClosed("closed"))
    }

    /// The scanner closed the connection: nothing more arrives, and later sends fail, as on a real socket.
    func closeFromScanner() {
        markClosed()
        inbound.close(.connectionClosed("closed by the scanner"))
    }

    private func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

final class SimulatedDatagramSocket: VENSDatagramSocket, @unchecked Sendable {
    let localIPv4: [UInt8] = [192, 0, 2, 10]
    let localPort: UInt16 = 55264
    let queue = MessageQueue()
    let scanner: SimulatedScanner
    /// Touched only by the scanner actor.
    nonisolated(unsafe) var heartbeats = 0

    init(scanner: SimulatedScanner) {
        self.scanner = scanner
    }

    func send(_ bytes: [UInt8]) async throws {
        // Like a cancelled NWConnection, a closed socket sends nothing.
        guard !queue.isClosed else { throw ScannerError.connectionClosed("socket closed") }
        await scanner.datagram(bytes, from: self)
    }

    func receive(timeout: Duration) async throws -> [UInt8]? {
        try await queue.next(timeout: timeout)
    }

    func close() async {
        queue.close()
    }
}
