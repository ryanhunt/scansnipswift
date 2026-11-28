import Foundation
import ScanSnipProtocol

/// Scans from a ScanSnap over Wi-Fi. One scan at a time; every scan registers, keeps the session alive with
/// heartbeats, and always ends the job and releases the scanner, after errors and cancellation too (an iX100
/// released mid-job stays busy until it is power-cycled).
///
/// Supports the iX100 (checked on hardware, firmware 0V00). The iX500's scan sequence differs and is not
/// implemented yet.
///
/// ```swift
/// let transport = NetworkTransport(host: "192.0.2.20")
/// let scanner = try await ScannerDiscovery.find(using: transport)
/// let client = WiFiScanner(transport: transport, scanner: scanner,
///                          configuration: .init(clientMAC: savedClientMAC))
/// for try await page in await client.scan(.init(colorMode: .automatic)) {
///     save(page.data, as: page.format)
/// }
/// ```
public actor WiFiScanner {
    public struct Configuration: Sendable {
        /// The MAC this client sends; the scanner keys the session to it. Use a stable, locally administered
        /// address per device (`randomClientMAC()` once, then store it).
        public var clientMAC: [UInt8]
        /// The scanner's password; nil uses the factory password (the last four characters of the serial).
        public var password: String?
        /// How long to wait for a scanner reply.
        public var commandTimeout: Duration = .seconds(15)
        /// How long to wait for a page image (feeding and scanning a sheet takes several seconds).
        public var readTimeout: Duration = .seconds(60)
        /// How long to wait for the first sheet to be put in.
        public var firstSheetTimeout: Duration = .seconds(180)
        /// How long to wait for another sheet after a page; when it passes, the job ends normally.
        public var nextSheetTimeout: Duration = .seconds(10)
        /// How often to read the paper sensor while waiting for a sheet.
        public var pollInterval: Duration = .milliseconds(500)
        /// How often to send heartbeats (the scanner drops a session after about 40 s without them).
        public var heartbeatInterval: Duration = .seconds(5)
        /// Called as a scan moves along, for status in the UI ("Insert a sheet", "Scanning page 2") and for
        /// diagnosis. Called on the scanner's actor: hop to the main actor before touching UI state.
        public var onProgress: (@Sendable (Progress) -> Void)?

        public init(clientMAC: [UInt8], password: String? = nil) {
            precondition(clientMAC.count == 6, "A MAC address is 6 bytes")
            self.clientMAC = clientMAC
            self.password = password
        }

        /// A random locally administered MAC (first byte 0x02). Generate it once per device and keep it.
        public static func randomClientMAC() -> [UInt8] {
            [0x02] + (0..<5).map { _ in UInt8.random(in: 0...255) }
        }
    }

    /// Where a scan is, reported through `Configuration.onProgress`.
    public enum Progress: Sendable, Equatable {
        /// Waiting for a sheet to be put in.
        case waitingForSheet
        /// A sheet is at the slot but the scanner has not loaded it yet.
        case sheetAtSlot
        /// The scanner has loaded a sheet; it is fed at once.
        case sheetLoaded
        /// Scanning the sheet that becomes this page (pages count from 0).
        case reading(page: Int)
        case pageRead(page: Int, bytes: Int)
        /// A sheet came back with no image (seen with blank sheets).
        case blankSheetSkipped
        /// Ending the job and releasing the scanner.
        case finishing
        /// The first bytes of the hardware status whenever they change, for diagnosis.
        case hardwareStatus([UInt8])
        /// The scanner's status, read right after registering (battery level on the iX100).
        case scannerStatus(VENS.ControlStatus)
    }

    /// What `readInfo()` reports about a scanner.
    public struct Info: Sendable, Equatable {
        /// Status word and, on the iX100, the battery level.
        public let status: VENS.ControlStatus?
        /// Vendor, product and firmware revision.
        public let inquiry: VENS.Inquiry?
        /// Lifetime page count and the other counters.
        public let counters: VENS.PageCounters?
    }

    public enum PageFormat: Sendable, Equatable {
        case jpeg
        /// Black and white: a 1-bit TIFF, CCITT Group 4.
        case tiff
    }

    public struct Page: Sendable, Equatable {
        /// Pages count from 0 in a scan.
        public let index: Int
        public let format: PageFormat
        public let data: Data
    }

    private let transport: any VENSTransport
    private let scanner: DiscoveredScanner
    private let configuration: Configuration
    private var scanning = false
    /// Sheets whose read came back with no image during the last scan (seen with blank sheets; they produce
    /// no page).
    public private(set) var blankPagesSkipped = 0
    private var stopRequested = false
    private var scanStream: (any VENSStream)?
    private var jobOpen = false
    private var registered = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: any VENSTransport, scanner: DiscoveredScanner, configuration: Configuration) {
        self.transport = transport
        self.scanner = scanner
        self.configuration = configuration
    }

    /// Scans sheets until none is put in within `nextSheetTimeout` after the last page, one job per sheet.
    /// Pages arrive as they are read. Stop iterating, or cancel the task, to end the scan early; the job is
    /// still ended and the scanner released, in the background: await `waitUntilIdle()` before scanning again
    /// or letting the app suspend.
    public func scan(_ parameters: VENS.IX100ScanParameters = .init()) -> AsyncThrowingStream<Page, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Page.self)
        guard !scanning else {
            continuation.finish(throwing: ScannerError.alreadyScanning)
            return stream
        }
        scanning = true
        blankPagesSkipped = 0
        stopRequested = false
        let task = Task { await self.run(parameters, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Ends the scan normally once the sheet being scanned, if any, is read: no more sheets are waited for,
    /// and the stream finishes without an error. Gentler than cancelling, which abandons a page mid-read;
    /// for example when an iOS app is about to run out of background time.
    public func stopAfterCurrentSheet() {
        if scanning { stopRequested = true }
    }

    /// Returns once no scan is running and its clean-up (ending the job, releasing the scanner) is done.
    public func waitUntilIdle() async {
        guard scanning else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func run(_ parameters: VENS.IX100ScanParameters,
                     _ continuation: AsyncThrowingStream<Page, Error>.Continuation) async {
        defer {
            scanning = false
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        do {
            try await session(parameters, continuation)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private var mac: [UInt8] { configuration.clientMAC }

    /// The status read when the last scan or `readInfo()` registered (battery level on the iX100).
    public private(set) var lastStatus: VENS.ControlStatus?

    /// Reads the scanner's status (battery), INQUIRY (product, firmware) and page counters, then releases it.
    /// Uses the scanner the way a scan does, so not while one runs (`ScannerError.alreadyScanning`).
    public func readInfo() async throws -> Info {
        guard !scanning else { throw ScannerError.alreadyScanning }
        scanning = true
        defer {
            scanning = false
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        guard scanner.model == .iX100 else { throw ScannerError.unsupportedModel(scanner.announcement.model) }
        guard let password = configuration.password ?? scanner.announcement.factoryPassword else {
            throw ScannerError.passwordRequired
        }
        var failure: Error?
        var inquiry: VENS.Inquiry?
        var counters: VENS.PageCounters?
        do {
            try await register(password: password)
            let stream = try await openScanChannel()
            scanStream = stream
            let identity = try await command(stream, VENS.Command.inquiry, inputLength: 0x60)
            if identity.isGood { inquiry = VENS.Inquiry(data: identity.data) }
            let count = try await command(stream, VENS.Command.counters, inputLength: 0x20)
            if count.isGood { counters = VENS.PageCounters(data: count.data) }
        } catch {
            failure = error
        }
        await Task { await self.finishSession() }.value
        if let failure { throw failure }
        return Info(status: lastStatus, inquiry: inquiry, counters: counters)
    }

    // MARK: Session

    private func session(_ parameters: VENS.IX100ScanParameters,
                         _ continuation: AsyncThrowingStream<Page, Error>.Continuation) async throws {
        guard scanner.model == .iX100 else { throw ScannerError.unsupportedModel(scanner.announcement.model) }
        guard let password = configuration.password ?? scanner.announcement.factoryPassword else {
            throw ScannerError.passwordRequired
        }
        var failure: Error?
        var heartbeat: (socket: any VENSDatagramSocket, task: Task<Void, Never>)?
        do {
            // Inside the clean-up path: a registration the scanner accepted is released even if what follows
            // it (the status read, or the reply itself) fails or is cancelled.
            try await register(password: password)
            heartbeat = try await startHeartbeat()
            try await scanPages(parameters, continuation)
        } catch {
            failure = error
        }
        // Clean up in a task of its own, so a cancelled scan still ends the job and releases the scanner.
        await Task { await self.finishSession() }.value
        if let heartbeat {
            heartbeat.task.cancel()
            await heartbeat.socket.close()
        }
        if let failure { throw failure }
    }

    private func register(password: String) async throws {
        let body = try wire { () throws(VENSError) in
            try VENS.registrationBody(interfaceVersion: scanner.announcement.interfaceVersion,
                                      hostIP: scanner.localIPv4, password: password, registrant: .mobile,
                                      date: Date(), timeZone: .current)
        }
        // Counted as registered from the moment the frame may reach the scanner, so a failure or cancellation
        // before the reply is read still releases it (a release from a client that does not hold it is ignored).
        registered = true
        let reply = try await control(.register, body: body)
        let status = try wire { () throws(VENSError) in try VENS.RegistrationStatus(reply: reply) }
        guard status == .accepted else {
            registered = false
            throw ScannerError.registrationRefused(status)
        }
        // The iOS app reads the status straight after registering; do the same (byte 11 of the reply looks
        // like the battery level).
        let statusReply = try await control(.status)
        lastStatus = VENS.ControlStatus(reply: statusReply)
        if let lastStatus { configuration.onProgress?(.scannerStatus(lastStatus)) }
    }

    /// Sends heartbeats until cancelled. If the socket closes (a network drop), it opens a new one.
    private func startHeartbeat() async throws -> (socket: any VENSDatagramSocket, task: Task<Void, Never>) {
        let first = try await transport.datagramSocket(port: VENS.discoveryPort)
        let holder = SocketHolder(first)
        let transport = transport
        let (hostIP, mac, interval) = (scanner.localIPv4, mac, configuration.heartbeatInterval)
        let task = Task {
            while !Task.isCancelled {
                var socket = holder.socket
                let beat = VENS.probe(hostIP: hostIP, hostMAC: mac, replyPort: socket.localPort,
                                      flag: VENS.heartbeatFlag, sequence: 1)
                try? await socket.send(beat)
                // Drain the scanner's 12-byte answers while waiting.
                let until = ContinuousClock.now + interval
                while ContinuousClock.now < until, !Task.isCancelled {
                    do {
                        _ = try await socket.receive(timeout: until - ContinuousClock.now)
                    } catch {
                        await socket.close()
                        guard let reopened = try? await transport.datagramSocket(port: VENS.discoveryPort) else {
                            try? await Task.sleep(until: until, clock: .continuous)
                            break
                        }
                        socket = reopened
                        holder.socket = reopened
                        break
                    }
                }
            }
        }
        return (HolderSocket(holder), task)
    }

    /// Ends an open job (on the scan connection, or a new one if that is gone) and releases the scanner.
    /// If the job cannot be ended, the scanner is not released: an iX100 released mid-job stays busy until it
    /// is power-cycled, while an unreleased session lapses about 40 s after the heartbeats stop.
    private func finishSession() async {
        configuration.onProgress?(.finishing)
        var jobEnded = true
        if jobOpen {
            jobEnded = false
            if let stream = scanStream, (try? await command(stream, VENS.Command.endJob))?.isGood == true {
                jobEnded = true
            }
            if !jobEnded, let stream = try? await openScanChannel() {
                jobEnded = (try? await command(stream, VENS.Command.endJob))?.isGood == true
                await stream.close()
            }
            jobOpen = false
        }
        if let stream = scanStream {
            await stream.close()
            scanStream = nil
        }
        if registered {
            if jobEnded { _ = try? await control(.release) }
            registered = false
        }
    }

    /// One short job per sheet, as the iOS app does for a single sheet: wait until a sheet is loaded, then
    /// start the job, feed, read and end it at once. A sheet that comes back with no image (seen with blank
    /// sheets) is counted in `blankPagesSkipped` and not yielded.
    private func scanPages(_ parameters: VENS.IX100ScanParameters,
                           _ continuation: AsyncThrowingStream<Page, Error>.Continuation) async throws {
        let block = VENS.iX100ParameterBlock(parameters)
        var index = 0
        var sheetsFed = 0
        // Every sheet is its own job with image index 0, so the iX500's per-job sheet limit does not apply.
        while !stopRequested {
            let first = sheetsFed == 0
            let stream = try await openScanChannel()
            scanStream = stream
            let timeout = first ? configuration.firstSheetTimeout : configuration.nextSheetTimeout
            guard try await waitForSheet(stream, timeout: timeout) else {
                await stream.close()
                scanStream = nil
                if first, !stopRequested { throw ScannerError.noSheet }
                return
            }
            try await expectGood("CancelRead", stream, VENS.Command.cancelRead)
            try await expectGood("SetParameters", stream, VENS.iX100SetParametersCommand(length: block.count),
                                 output: block)
            jobOpen = true
            try await expectGood("StartJob", stream, VENS.Command.startJob,
                                 output: [UInt8](repeating: 0, count: 8), inputLength: 8)
            let feed = try await command(stream, VENS.Command.startPaper)
            if feed.isCheckCondition {
                let sense = try await requestSense(stream)
                if sense.paperProblem == .feederEmpty {
                    // The sheet was taken out between the sensor reading and the feed.
                    try await endJob(stream)
                    if first { throw ScannerError.noSheet }
                    return
                }
                throw sense.paperProblem != nil ? ScannerError.paper(sense) : ScannerError.commandFailed("StartPaper", sense)
            } else if !feed.isGood {
                throw ScannerError.unexpectedStatus("StartPaper", feed.status)
            }
            // Each job counts images from 0.
            configuration.onProgress?(.reading(page: index))
            let image = try await readImage(stream, index: 0)
            try await endJob(stream)
            await stream.close()
            scanStream = nil
            sheetsFed += 1
            if image.isEmpty {
                // Some blank sheets come back with no image, in colour and automatic modes (2026-11-27);
                // probably the scanner's blank-page removal, though one nearly blank sheet scanned.
                blankPagesSkipped += 1
                configuration.onProgress?(.blankSheetSkipped)
            } else {
                configuration.onProgress?(.pageRead(page: index, bytes: image.count))
                continuation.yield(Page(index: index, format: parameters.returnsTIFF ? .tiff : .jpeg,
                                        data: Data(image)))
                index += 1
            }
            try Task.checkCancellation()
        }
    }

    private func endJob(_ stream: any VENSStream) async throws {
        try await expectGood("EndJob", stream, VENS.Command.endJob)
        jobOpen = false
    }

    /// Polls the hardware status until the scanner has loaded a sheet (`VENS.iX100SheetReady`). A sheet that
    /// only touches the entry slot is not ready (the app never feeds it; doing so stalled a read). After a
    /// page the sensor reads empty at once, as in the app's captures. Returns false on timeout.
    private func waitForSheet(_ stream: any VENSStream, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        var lastStatus: [UInt8]?
        var lastState: Progress?
        func report(_ state: Progress) {
            if state != lastState { configuration.onProgress?(state) }
            lastState = state
        }
        report(.waitingForSheet)
        while true {
            let status = try await command(stream, VENS.Command.hardwareStatus, inputLength: 0x20)
            guard status.isGood else { throw ScannerError.unexpectedStatus("HardwareStatus", status.status) }
            let head = Array(status.data.prefix(4))
            if head != lastStatus { configuration.onProgress?(.hardwareStatus(head)) }
            lastStatus = head
            switch VENS.iX100SheetReady(status.data) {
            case true?:
                report(.sheetLoaded)
                return true
            case false?:
                report(VENS.hopperHasPaper(status.data) == true ? .sheetAtSlot : .waitingForSheet)
            case nil: throw ScannerError.protocolError(.truncated(expected: 3, actual: status.data.count))
            }
            if ContinuousClock.now >= deadline || stopRequested { return false }
            try await Task.sleep(for: configuration.pollInterval)
        }
    }

    /// Reads one page. A page larger than one read comes in several; every read after the first repeats the
    /// image's opening segments, which are checked and dropped (`VENS.iX100ContinuationPrefixLength`).
    private func readImage(_ stream: any VENSStream, index: Int) async throws -> [UInt8] {
        var image: [UInt8] = []
        var first = true
        while true {
            let reply = try await command(
                stream, VENS.readImageCommand(back: false, imageIndex: index, length: VENS.iX100ReadLength),
                inputLength: VENS.iX100ReadLength, timeout: configuration.readTimeout)
            // The chunk number stays 0 on the iX100's continuation reads.
            let piece = try wire { () throws(VENSError) in
                try VENS.ImageChunk(data: reply.data, imageIndex: index, chunk: 0)
            }
            if first {
                image += piece.bytes
            } else {
                let bytes = Array(piece.bytes)
                guard let prefix = VENS.iX100ContinuationPrefixLength(image), prefix >= 2,
                      image.count >= prefix, bytes.count >= prefix, bytes[2..<prefix] == image[2..<prefix]
                else { throw ScannerError.commandFailed("ReadImage: a continuation read in an unknown layout", nil) }
                image += bytes[prefix...]
            }
            first = false
            if reply.isGood { continue }
            guard reply.isCheckCondition else { throw ScannerError.unexpectedStatus("ReadImage", reply.status) }
            let sense = try await requestSense(stream)
            guard sense.endOfMedium else { throw ScannerError.commandFailed("ReadImage", sense) }
            return image
        }
    }

    // MARK: Channels

    /// One control command on its own connection, sent the moment the greeting arrives.
    private func control(_ command: VENS.ControlCommand, body: [UInt8] = []) async throws -> [UInt8] {
        let stream = try await transport.connect(port: VENS.controlPort)
        do {
            let greeting = try await stream.receiveFrame(timeout: configuration.commandTimeout)
            guard greeting.count == VENS.serverHeaderLength else {
                throw ScannerError.protocolError(.badLength(greeting.count))
            }
            try await stream.send(VENS.clientFrame(command: command.rawValue, mac: mac, body: body))
            let reply = try await stream.receiveFrame(timeout: configuration.commandTimeout)
            await stream.close()
            return reply
        } catch {
            await stream.close()
            throw error
        }
    }

    private func openScanChannel() async throws -> any VENSStream {
        let stream = try await transport.connect(port: VENS.scanPort)
        do {
            _ = try await stream.receiveFrame(timeout: configuration.commandTimeout)
            return stream
        } catch {
            await stream.close()
            throw error
        }
    }

    private func command(_ stream: any VENSStream, _ cdb: [UInt8], output: [UInt8] = [], inputLength: Int = 0,
                         timeout: Duration? = nil) async throws -> VENS.SCSIReply {
        let frame: [UInt8]
        do {
            try await stream.send(VENS.scsiFrame(mac: mac, cdb: cdb, output: output, inputLength: inputLength))
            frame = try await stream.receiveFrame(timeout: timeout ?? configuration.commandTimeout)
        } catch {
            // A late reply could still arrive and be taken for the next command's: never reuse this
            // connection. The clean-up then ends the job on a new one.
            await stream.close()
            if let current = scanStream, current as AnyObject === stream as AnyObject { scanStream = nil }
            throw error
        }
        return try wire { () throws(VENSError) in try VENS.SCSIReply(frame: frame) }
    }

    private func expectGood(_ name: String, _ stream: any VENSStream, _ cdb: [UInt8], output: [UInt8] = [],
                            inputLength: Int = 0) async throws {
        let reply = try await command(stream, cdb, output: output, inputLength: inputLength)
        guard !reply.isGood else { return }
        guard reply.isCheckCondition else { throw ScannerError.unexpectedStatus(name, reply.status) }
        let sense = try? await requestSense(stream)
        throw ScannerError.commandFailed(name, sense)
    }

    private func requestSense(_ stream: any VENSStream) async throws -> SCSISense {
        let reply = try await command(stream, VENS.Command.requestSense, inputLength: 18)
        guard let sense = SCSISense(reply.data) else {
            throw ScannerError.protocolError(.truncated(expected: 18, actual: reply.data.count))
        }
        return sense
    }
}

/// The heartbeat's current socket, which the heartbeat task replaces if it closes.
final class SocketHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: any VENSDatagramSocket

    init(_ socket: any VENSDatagramSocket) {
        current = socket
    }

    var socket: any VENSDatagramSocket {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Closes whichever socket the heartbeat holds at the end.
struct HolderSocket: VENSDatagramSocket {
    let holder: SocketHolder
    init(_ holder: SocketHolder) { self.holder = holder }
    var localIPv4: [UInt8] { holder.socket.localIPv4 }
    var localPort: UInt16 { holder.socket.localPort }
    func send(_ bytes: [UInt8]) async throws { try await holder.socket.send(bytes) }
    func receive(timeout: Duration) async throws -> [UInt8]? { try await holder.socket.receive(timeout: timeout) }
    func close() async { await holder.socket.close() }
}
