import Foundation
import ScanSnipProtocol
import ScanSnipScanner

/// Scans from a ScanSnap over USB, in colour, one sheet at a time. One scan at a time; a scan always ends the
/// job, after errors and cancellation too.
///
/// Checked on an iX100 (firmware 0V00, 2026-11-29) with ScanSnap Cloud mode off; in that mode the scanner
/// refuses to feed (`SCSISense.PaperProblem.heldByCloudOrMobile`). The iX500's duplex sequence is not
/// implemented yet. The caller opens and closes the channel (`IOUSBHostChannel` on macOS).
///
/// ```swift
/// let channel = try IOUSBHostChannel.open()
/// let scanner = USBScanner(channel: channel, configuration: .init(resolution: 300))
/// for try await page in await scanner.scan() {
///     save(page.data, format: page.format, width: page.width, height: page.height)
/// }
/// await channel.close()
/// ```
public actor USBScanner {
    public struct Configuration: Sendable {
        /// Dots per inch across and along the page: 150, 200, 300 or 600.
        public var resolution: Int
        /// The pages' pixel format. The scanner always reads colour; grey and black and white are made from it
        /// on this device (`PixelConversion`).
        public var colorMode: ColorMode = .color
        /// How long to wait for an ordinary command.
        public var commandTimeout: Duration = .seconds(10)
        /// How long to wait for one image read (the first waits while the sheet feeds).
        public var readTimeout: Duration = .seconds(30)
        /// How long to wait for the first sheet to be put in.
        public var firstSheetTimeout: Duration = .seconds(180)
        /// How long to wait for another sheet after a page; when it passes, the scan ends normally.
        public var nextSheetTimeout: Duration = .seconds(10)
        /// How often to read the paper sensor while waiting for a sheet.
        public var pollInterval: Duration = .milliseconds(200)
        /// Called as a scan moves along. Called on the scanner's actor: hop to the main actor for UI state.
        public var onProgress: (@Sendable (Progress) -> Void)?

        public init(resolution: Int = 150, colorMode: ColorMode = .color) {
            self.resolution = resolution
            self.colorMode = colorMode
        }
    }

    public enum ColorMode: Sendable, Equatable {
        case color
        case gray
        /// One bit per pixel; pixels darker than `threshold` (of 255) are black.
        case blackAndWhite(threshold: UInt8 = 128)
    }

    /// How a page's `data` is laid out. Lines run from the edge fed first.
    public enum PixelFormat: Sendable, Equatable {
        /// 3 bytes per pixel: red, green, blue.
        case rgb8
        /// 1 byte per pixel, 0 black to 255 white.
        case gray8
        /// 1 bit per pixel, the most significant first, 1 black; each line padded to whole bytes.
        case blackAndWhite1

        /// Bytes in one line of `width` pixels.
        public func bytesPerLine(width: Int) -> Int {
            switch self {
            case .rgb8: width * 3
            case .gray8: width
            case .blackAndWhite1: (width + 7) / 8
            }
        }
    }

    /// Where a scan is, reported through `Configuration.onProgress`.
    public enum Progress: Sendable, Equatable {
        /// Waiting for a sheet to be put in.
        case waitingForSheet
        /// The scanner has loaded a sheet; it is fed at once.
        case sheetLoaded
        /// Scanning the sheet that becomes this page (pages count from 0).
        case reading(page: Int)
        case pageRead(page: Int, lines: Int)
        /// A sheet came back with no image.
        case blankSheetSkipped
        /// Ending the job.
        case finishing
        /// The first 8 bytes of the hardware status whenever they change, for diagnosis.
        case hardwareStatus([UInt8])
    }

    /// One side of a sheet, lines in the order the sheet was fed (the edge that went in first at the top).
    public struct Page: Sendable, Equatable {
        /// Pages count from 0 in a scan.
        public let index: Int
        public let width: Int
        public let height: Int
        public let resolution: Int
        public let format: PixelFormat
        /// `format.bytesPerLine(width:) * height` bytes.
        public let data: Data
    }

    /// What `readInfo()` reports.
    public struct Info: Sendable, Equatable {
        /// Vendor, product and firmware revision.
        public let inquiry: VENS.Inquiry?
        /// The 32-byte hardware status (byte 2 bit 7: a sheet is loaded).
        public let hardwareStatus: [UInt8]
    }

    private let channel: any SCSIChannel
    private let configuration: Configuration
    private let window: FujitsuUSB.Window
    private var scanning = false
    private var stopRequested = false
    private var jobStarted = false
    private var lastStatus: [UInt8] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Sheets that came back with no image during the last scan.
    public private(set) var blankPagesSkipped = 0

    public init(channel: any SCSIChannel, configuration: Configuration = .init()) {
        precondition([150, 200, 300, 600].contains(configuration.resolution), "Resolution is 150, 200, 300 or 600")
        self.channel = channel
        self.configuration = configuration
        window = FujitsuUSB.Window(resolution: configuration.resolution)
    }

    /// Scans sheets until none is put in within `nextSheetTimeout` after the last page. Pages arrive as they
    /// are read. Stop iterating, or cancel the task, to end early; the job is still ended, in the background:
    /// await `waitUntilIdle()` before scanning again or closing the channel.
    public func scan() -> AsyncThrowingStream<Page, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Page.self)
        guard !scanning else {
            continuation.finish(throwing: ScannerError.alreadyScanning)
            return stream
        }
        scanning = true
        stopRequested = false
        blankPagesSkipped = 0
        let task = Task { await self.run(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Ends the scan normally once the sheet being scanned, if any, is read.
    public func stopAfterCurrentSheet() {
        if scanning { stopRequested = true }
    }

    /// Returns once no scan is running.
    public func waitUntilIdle() async {
        guard scanning else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Reads INQUIRY and the hardware status. Not during a scan.
    public func readInfo() async throws -> Info {
        guard !scanning else { throw ScannerError.alreadyScanning }
        try await wake()
        let inquiry = try await command("INQUIRY", FujitsuUSB.Command.inquiry, inputLength: 0x60)
        let status = try await command("hardware status", FujitsuUSB.Command.hardwareStatus, inputLength: 0x20)
        return Info(inquiry: VENS.Inquiry(data: inquiry), hardwareStatus: status)
    }

    // MARK: The scan

    private func run(_ continuation: AsyncThrowingStream<Page, Error>.Continuation) async {
        do {
            try await wake()
            var index = 0
            while !stopRequested {
                let timeout = index == 0 ? configuration.firstSheetTimeout : configuration.nextSheetTimeout
                guard try await waitForSheet(timeout: timeout) else {
                    if index == 0 && !stopRequested { throw ScannerError.noSheet }
                    break
                }
                if let page = try await scanSheet(index: index) {
                    continuation.yield(page)
                    index += 1
                }
            }
            await finish(cleanly: true)
            continuation.finish()
        } catch {
            await finish(cleanly: false)
            continuation.finish(throwing: error)
        }
        scanning = false
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// TEST UNIT READY until it answers: the first transfer after the scanner wakes can fail once.
    private func wake() async throws {
        var lastError: (any Error)?
        for attempt in 1...5 {
            do {
                let result = try await channel.run(FujitsuUSB.Command.testUnitReady, output: [], inputLength: 0,
                                                   timeout: .seconds(2))
                if result.status.isGood { return }
                _ = try? await requestSense()
                lastError = ScannerError.unexpectedStatus("TEST UNIT READY", UInt32(result.status.scsiStatus))
            } catch {
                lastError = error
            }
            if attempt < 5 { try await Task.sleep(for: .milliseconds(500)) }
        }
        throw lastError ?? ScannerError.noAnswer
    }

    /// Polls the paper sensor until a sheet is loaded (true) or the time passes (false).
    private func waitForSheet(timeout: Duration) async throws -> Bool {
        report(.waitingForSheet)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let status = try await command("hardware status", FujitsuUSB.Command.hardwareStatus, inputLength: 0x20)
            let head = Array(status.prefix(8))
            if head != lastStatus {
                lastStatus = head
                report(.hardwareStatus(head))
            }
            if status.count > 2, status[2] & 0x80 != 0 {
                report(.sheetLoaded)
                return true
            }
            if stopRequested || clock.now >= deadline { return false }
            try await Task.sleep(for: configuration.pollInterval)
        }
    }

    /// Sets the scanner up, feeds the loaded sheet and reads its image. Nil for a sheet with no image.
    private func scanSheet(index: Int) async throws -> Page? {
        jobStarted = true
        try await command("select feeder", FujitsuUSB.Command.selectFeeder)
        let preRead = window.preReadData
        try await command("pre-read setup", FujitsuUSB.Command.sendDiagnostic(length: preRead.count), output: preRead)
        for page in FujitsuUSB.Window.modePages {
            try await command("MODE SELECT", FujitsuUSB.Command.modeSelect(length: page.count), output: page)
        }
        let windowData = window.windowData
        try await command("SET WINDOW", FujitsuUSB.Command.setWindow(length: windowData.count), output: windowData)
        let gamma = FujitsuUSB.Window.linearGamma
        try await command("SEND gamma", FujitsuUSB.Command.sendGamma(length: gamma.count), output: gamma)
        try await lampOn()
        report(.reading(page: index))
        try await command("feed", FujitsuUSB.Command.feed, timeout: configuration.readTimeout)
        try await command("SCAN", FujitsuUSB.Command.scan, output: [0])
        let sizeData = try await command("READ pixel size", FujitsuUSB.Command.readPixelSize, inputLength: 0x20)
        guard let size = FujitsuUSB.PixelSize(data: sizeData), size.width > 0 else {
            throw ScannerError.commandFailed("READ pixel size", nil)
        }
        let bytesPerLine = size.width * 3
        let image = try await readImage(bytesPerLine: bytesPerLine, maximumLines: max(size.lines, window.maximumLines))
        let lines = image.count / bytesPerLine
        guard lines > 0 else {
            blankPagesSkipped += 1
            report(.blankSheetSkipped)
            return nil
        }
        report(.pageRead(page: index, lines: lines))
        let rgb = FujitsuUSB.rgbFromSamples(Array(image.prefix(lines * bytesPerLine)))
        let (format, pixels): (PixelFormat, [UInt8]) = switch configuration.colorMode {
        case .color: (.rgb8, rgb)
        case .gray: (.gray8, PixelConversion.gray(fromRGB: rgb))
        case .blackAndWhite(let threshold):
            (.blackAndWhite1, PixelConversion.blackAndWhite(fromGray: PixelConversion.gray(fromRGB: rgb), width: size.width,
                                                            threshold: threshold))
        }
        return Page(index: index, width: size.width, height: lines, resolution: configuration.resolution, format: format,
                    data: Data(pixels))
    }

    /// Lamp on, retried while the scanner says it is not ready yet (sense key 2) or busy.
    private func lampOn() async throws {
        for attempt in 1...20 {
            do {
                try await command("lamp on", FujitsuUSB.Command.lampOn)
                return
            } catch let error as ScannerError {
                let notReady = switch error {
                case .commandFailed(_, let sense): sense?.key == 2
                case .unexpectedStatus(_, let status): status == UInt32(FujitsuUSB.StatusPacket.busy)
                default: false
                }
                guard notReady, attempt < 20 else { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Image reads of whole lines until the scanner reports the end of the page (CHECK CONDITION with end of
    /// medium; with incorrect length, the information field is how many of the bytes asked for were not real).
    private func readImage(bytesPerLine: Int, maximumLines: Int) async throws -> [UInt8] {
        let length = max(1, 0x40000 / bytesPerLine) * bytesPerLine
        let limit = (maximumLines + 1) * bytesPerLine
        var image: [UInt8] = []
        var waits = 0
        while image.count < limit {
            try Task.checkCancellation()
            let result = try await channel.run(FujitsuUSB.Command.readImage(length: length), output: [],
                                               inputLength: length, timeout: configuration.readTimeout)
            if result.status.isGood {
                image += result.data
                continue
            }
            guard result.status.isCheckCondition else {
                throw ScannerError.unexpectedStatus("READ", UInt32(result.status.scsiStatus))
            }
            guard let sense = try await requestSense() else { throw ScannerError.commandFailed("READ", nil) }
            if sense.key == 3, sense.additionalCode == 0x80, sense.additionalQualifier == 0x13, waits < 300 {
                // No data yet (from Scan's driver): wait and read again.
                waits += 1
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if sense.endOfMedium {
                var data = result.data
                if sense.incorrectLength {
                    data = Array(data.prefix(max(0, length - Int(sense.information))))
                }
                image += data
                return image
            }
            throw sense.paperProblem != nil ? ScannerError.paper(sense) : ScannerError.commandFailed("READ", sense)
        }
        return image
    }

    /// Ends the job. A clean end feeds once more (answered 3/80/03, no paper) and clears buffering; after an
    /// error or cancellation the scanner is halted and the scan cancelled, with short timeouts, since a stuck
    /// scanner would otherwise hold each command for the full timeout.
    private func finish(cleanly: Bool) async {
        guard jobStarted else { return }
        jobStarted = false
        report(.finishing)
        let short = Duration.seconds(3)
        if cleanly {
            _ = try? await channel.run(FujitsuUSB.Command.feed, output: [], inputLength: 0, timeout: short)
            _ = try? await requestSense()
        } else {
            _ = try? await channel.run(FujitsuUSB.Command.halt, output: [], inputLength: 0, timeout: short)
            _ = try? await channel.run(FujitsuUSB.Command.cancel, output: [], inputLength: 0, timeout: short)
        }
        let end = FujitsuUSB.Window.endPage
        _ = try? await channel.run(FujitsuUSB.Command.modeSelect(length: end.count), output: end, inputLength: 0,
                                   timeout: short)
    }

    // MARK: Commands

    /// Runs one command. CHECK CONDITION becomes `ScannerError.paper` or `.commandFailed` with the sense data.
    @discardableResult
    private func command(_ name: String, _ cdb: [UInt8], output: [UInt8] = [], inputLength: Int = 0,
                         timeout: Duration? = nil) async throws -> [UInt8] {
        let result = try await channel.run(cdb, output: output, inputLength: inputLength,
                                           timeout: timeout ?? configuration.commandTimeout)
        if result.status.isGood { return result.data }
        guard result.status.isCheckCondition else {
            throw ScannerError.unexpectedStatus(name, UInt32(result.status.scsiStatus))
        }
        let sense = try? await requestSense()
        if let sense, sense.paperProblem != nil { throw ScannerError.paper(sense) }
        throw ScannerError.commandFailed(name, sense)
    }

    private func requestSense() async throws -> SCSISense? {
        let result = try await channel.run(FujitsuUSB.Command.requestSense, output: [], inputLength: 0x12,
                                           timeout: configuration.commandTimeout)
        return SCSISense(result.data)
    }

    private func report(_ progress: Progress) {
        configuration.onProgress?(progress)
    }
}
