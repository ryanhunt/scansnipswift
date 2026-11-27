import Foundation
import Testing
import ScanSnipProtocol
@testable import ScanSnipScanner

private let mac: [UInt8] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
private let jpeg: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]
private let otherJPEG: [UInt8] = [0xFF, 0xD8, 4, 5, 6, 7, 0xFF, 0xD9]

/// Short timeouts so the tests run in well under a second each.
private func configuration(password: String? = nil) -> WiFiScanner.Configuration {
    var configuration = WiFiScanner.Configuration(clientMAC: mac, password: password)
    configuration.commandTimeout = .seconds(1)
    configuration.readTimeout = .seconds(1)
    configuration.firstSheetTimeout = .milliseconds(300)
    configuration.nextSheetTimeout = .milliseconds(150)
    configuration.pollInterval = .milliseconds(5)
    configuration.heartbeatInterval = .milliseconds(20)
    return configuration
}

private func client(_ scanner: SimulatedScanner, password: String? = nil) async throws -> WiFiScanner {
    let transport = SimulatedTransport(scanner: scanner)
    let found = try await ScannerDiscovery.find(using: transport, timeout: .seconds(1), interval: .milliseconds(50))
    return WiFiScanner(transport: transport, scanner: found, configuration: configuration(password: password))
}

private func collect(_ stream: AsyncThrowingStream<WiFiScanner.Page, Error>) async throws -> [WiFiScanner.Page] {
    var pages: [WiFiScanner.Page] = []
    for try await page in stream { pages.append(page) }
    return pages
}

/// Waits until the scanner has been released (the clean-up runs after the stream ends).
private func waitForRelease(_ scanner: SimulatedScanner) async throws {
    for _ in 0..<200 {
        if await scanner.registeredMAC == nil, await scanner.events.last == "release" { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("the scanner was not released")
}

@Suite struct DiscoveryTests {
    @Test func findsTheScannerAndTheLocalAddress() async throws {
        let found = try await ScannerDiscovery.find(using: SimulatedTransport(scanner: SimulatedScanner()),
                                                    timeout: .seconds(1), interval: .milliseconds(50))
        #expect(found.model == .iX100)
        #expect(found.localIPv4 == [192, 0, 2, 10])
        #expect(found.announcement.factoryPassword == "2345")
    }
}

@Suite struct WiFiScannerTests {
    @Test func scansEachSheetAndEndsWhenNoMoreCome() async throws {
        let scanner = SimulatedScanner(sheets: [jpeg, otherJPEG])
        let pages = try await collect(client(scanner).scan())
        #expect(pages.map(\.index) == [0, 1])
        #expect(pages.map(\.data) == [Data(jpeg), Data(otherJPEG)])
        #expect(pages.allSatisfy { $0.format == .jpeg })
        try await waitForRelease(scanner)
        // One job per sheet, each started only once the sheet is loaded.
        #expect(await scanner.events == ["register", "status", "D8", "D4(128)", "D5", "E0", "28#0", "03", "D6",
                                         "D8", "D4(128)", "D5", "E0", "28#0", "03", "D6", "release"])
        #expect(await scanner.jobOpen == false)
        #expect(await scanner.stuck == false)
    }

    @Test func blackAndWhiteSendsOneWindowAndReturnsTIFF() async throws {
        let tiff: [UInt8] = Array("II*\u{0}".utf8) + [1, 2, 3]
        let scanner = SimulatedScanner(sheets: [tiff])
        let pages = try await collect(client(scanner).scan(.init(colorMode: .blackAndWhite)))
        #expect(pages.map(\.format) == [.tiff])
        #expect(pages.first?.data == Data(tiff))
        #expect(await scanner.events.contains("D4(80)"))
    }

    @Test func wrongPasswordIsRefusedBeforeAnyScan() async throws {
        let scanner = SimulatedScanner(sheets: [jpeg])
        await #expect(throws: ScannerError.registrationRefused(.wrongPassword)) {
            try await collect(client(scanner, password: "9999").scan())
        }
        #expect(await scanner.events == ["register"])
    }

    @Test func noSheetStartsNoJobAndReleases() async throws {
        let scanner = SimulatedScanner()
        await #expect(throws: ScannerError.noSheet) {
            try await collect(client(scanner).scan())
        }
        try await waitForRelease(scanner)
        #expect(await scanner.events == ["register", "status", "release"])
        #expect(await scanner.stuck == false)
    }

    @Test func aFailedReadStillEndsTheJobOnANewConnection() async throws {
        let scanner = SimulatedScanner(sheets: [jpeg])
        await scanner.setFailReadOfPage(0)
        await #expect(throws: ScannerError.connectionClosed("closed by the scanner")) {
            try await collect(client(scanner).scan())
        }
        try await waitForRelease(scanner)
        #expect(await scanner.events.suffix(3) == ["28#0", "D6", "release"])
        #expect(await scanner.scanConnections == 2)  // the dead connection was not reused
        #expect(await scanner.stuck == false)
    }

    @Test func sheetsThatComeBackEmptyAreSkipped() async throws {
        // Some blank sheets come back from the iX100 with no image. They are counted, not yielded, and the
        // pages that follow keep counting from where they were.
        let scanner = SimulatedScanner(sheets: [jpeg, [], otherJPEG])
        let wifi = try await client(scanner)
        let pages = try await collect(wifi.scan())
        #expect(pages.map(\.index) == [0, 1])
        #expect(pages.map(\.data) == [Data(jpeg), Data(otherJPEG)])
        #expect(await wifi.blankPagesSkipped == 1)
        try await waitForRelease(scanner)
        #expect(await scanner.events.filter { $0 == "E0" }.count == 3)
    }

    @Test func aLateReplyIsNotTakenForTheNextCommand() async throws {
        // On hardware a read answered after 70 s, past the timeout; its reply must not be read as the
        // clean-up's end-of-job answer. The client drops the connection and ends the job on a new one.
        let scanner = SimulatedScanner(sheets: [jpeg])
        await scanner.setLateReads(true)
        await #expect(throws: ScannerError.timedOut("reply")) {
            try await collect(client(scanner).scan())
        }
        try await waitForRelease(scanner)
        #expect(await scanner.events.suffix(3) == ["28#0", "D6", "release"])
        #expect(await scanner.scanConnections == 2)  // the end of job went over a fresh connection
        #expect(await scanner.jobOpen == false)
        #expect(await scanner.stuck == false)
    }

    @Test func aPageLargerThanOneReadIsJoinedWithoutTheRepeatedHeader() async throws {
        // As the iX100 sent a 425 KB page: two reads, the second repeating SOI-less APP0 and COM segments.
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        let comment: [UInt8] = [0xFF, 0xFE, 0x00, 0x15] + [UInt8](repeating: 0x41, count: 19)
        let body = (0..<400_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let big: [UInt8] = [0xFF, 0xD8] + app0 + comment + body + [0xFF, 0xD9]
        let scanner = SimulatedScanner(sheets: [big])
        let pages = try await collect(client(scanner).scan())
        #expect(pages.count == 1)
        #expect(pages.first?.data == Data(big))
        #expect(await scanner.events.filter { $0 == "28#0" }.count == 2)
    }

    @Test func stoppingBetweenSheetsReleasesAndAllowsAnotherScan() async throws {
        let scanner = SimulatedScanner(sheets: [jpeg, otherJPEG, jpeg])
        let wifi = try await client(scanner)
        for try await page in await wifi.scan() {
            #expect(page.index == 0)
            break
        }
        await wifi.waitUntilIdle()
        #expect(await scanner.events.last == "release")
        #expect(await scanner.jobOpen == false)
        #expect(await scanner.stuck == false)
        // The clean-up is finished, so a new scan starts at once instead of failing with alreadyScanning.
        let more = try await collect(wifi.scan())
        #expect(more.count == 2)
    }

    @Test func cancellingMidJobEndsTheJobOnANewConnectionAndReleases() async throws {
        let scanner = SimulatedScanner(sheets: [jpeg])
        await scanner.setLateReads(true)  // the read stays unanswered, so the cancel lands inside the job
        let wifi = try await client(scanner)
        let consumer = Task { try await collect(wifi.scan()) }
        for _ in 0..<200 where await scanner.events.last != "28#0" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await scanner.events.last == "28#0")
        consumer.cancel()
        await wifi.waitUntilIdle()
        #expect(await scanner.events.suffix(3) == ["28#0", "D6", "release"])
        #expect(await scanner.scanConnections == 2)
        #expect(await scanner.jobOpen == false)
        #expect(await scanner.stuck == false)
    }

    @Test func aFailureRightAfterRegisteringStillReleases() async throws {
        let scanner = SimulatedScanner(sheets: [jpeg])
        await scanner.setDropStatus(true)
        let wifi = try await client(scanner)
        await #expect(throws: ScannerError.connectionClosed("closed by the scanner")) {
            try await collect(wifi.scan())
        }
        await wifi.waitUntilIdle()
        #expect(await scanner.events == ["register", "status", "release"])
        #expect(await scanner.registeredMAC == nil)
    }

    @Test func aJobThatCannotBeEndedIsNotReleased() async throws {
        // Releasing mid-job leaves an iX100 busy until power-cycled; an unreleased session lapses instead.
        let scanner = SimulatedScanner(sheets: [jpeg])
        await scanner.setFailEndJob(true)
        let wifi = try await client(scanner)
        await #expect(throws: ScannerError.self) {
            try await collect(wifi.scan())
        }
        await wifi.waitUntilIdle()
        let events = await scanner.events
        #expect(events.contains("D6"))
        #expect(!events.contains("release"))
        #expect(await scanner.stuck == false)
    }

    @Test func heartbeatsReopenAClosedSocket() async throws {
        let scanner = SimulatedScanner()
        await scanner.setCloseSocketsAfterHeartbeats(2)
        _ = try? await collect(client(scanner).scan())
        // One socket for discovery, then the heartbeat's first and at least one replacement.
        #expect(await scanner.datagramSockets >= 3)
        #expect(await scanner.heartbeats >= 4)
    }

    @Test func oneScanAtATime() async throws {
        let scanner = SimulatedScanner()
        let wifi = try await client(scanner)
        let first = await wifi.scan()
        await #expect(throws: ScannerError.alreadyScanning) {
            try await collect(wifi.scan())
        }
        await #expect(throws: ScannerError.noSheet) {
            try await collect(first)
        }
    }

    @Test func heartbeatsRunDuringTheScan() async throws {
        let scanner = SimulatedScanner()
        _ = try? await collect(client(scanner).scan())
        #expect(await scanner.heartbeats >= 2)
    }

    @Test func theIX500IsNotSupportedYet() async throws {
        let scanner = SimulatedScanner()
        await scanner.setModel("ScanSnap iX500")
        await #expect(throws: ScannerError.unsupportedModel("ScanSnap iX500")) {
            try await collect(client(scanner).scan())
        }
        #expect(await scanner.events.isEmpty)
    }

    @Test func aReleaseMidJobLeavesTheSimulatedScannerStuck() async throws {
        // Checks the simulation itself, which the clean-up tests rely on.
        let scanner = SimulatedScanner()
        let transport = SimulatedTransport(scanner: scanner)
        let control = try await transport.connect(port: VENS.controlPort)
        _ = try await control.receiveFrame(timeout: .seconds(1))
        let body = try VENS.registrationBody(interfaceVersion: 6, hostIP: [192, 0, 2, 10], password: "2345",
                                             registrant: .mobile, date: Date(), timeZone: .current)
        try await control.send(VENS.clientFrame(command: 0x11, mac: mac, body: body))
        _ = try await control.receiveFrame(timeout: .seconds(1))
        let scan = try await transport.connect(port: VENS.scanPort)
        _ = try await scan.receiveFrame(timeout: .seconds(1))
        try await scan.send(VENS.scsiFrame(mac: mac, cdb: VENS.Command.startJob, output: [UInt8](repeating: 0, count: 8),
                                           inputLength: 8))
        _ = try await scan.receiveFrame(timeout: .seconds(1))
        let release = try await transport.connect(port: VENS.controlPort)
        _ = try await release.receiveFrame(timeout: .seconds(1))
        try await release.send(VENS.clientFrame(command: 0x12, mac: mac))
        _ = try await release.receiveFrame(timeout: .seconds(1))
        #expect(await scanner.stuck)
    }
}

@Suite struct BufferTests {
    @Test func readsExactAmountsAcrossAppends() async throws {
        let buffer = ByteBuffer()
        buffer.append([1, 2])
        async let read = buffer.read(3, timeout: .seconds(1), operation: "test")
        try await Task.sleep(for: .milliseconds(10))
        buffer.append([3, 4])
        #expect(try await read == [1, 2, 3])
        #expect(try await buffer.read(1, timeout: .seconds(1), operation: "test") == [4])
    }

    @Test func timesOutAndReportsClosure() async throws {
        let buffer = ByteBuffer()
        await #expect(throws: ScannerError.timedOut("test")) {
            try await buffer.read(1, timeout: .milliseconds(10), operation: "test")
        }
        buffer.close(.connectionClosed("gone"))
        await #expect(throws: ScannerError.connectionClosed("gone")) {
            try await buffer.read(1, timeout: .seconds(1), operation: "test")
        }
    }

    @Test func messageQueueTellsATimeoutFromAClosedSocket() async throws {
        let queue = MessageQueue()
        #expect(try await queue.next(timeout: .milliseconds(10)) == nil)
        queue.push([7])
        #expect(try await queue.next(timeout: .seconds(1)) == [7])
        queue.close()
        await #expect(throws: ScannerError.connectionClosed("socket closed")) {
            try await queue.next(timeout: .seconds(1))
        }
    }
}
