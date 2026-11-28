import Foundation
import Testing
import ScanSnipProtocol
import ScanSnipScanner
@testable import ScanSnipUSB

@Suite struct USBScannerTests {
    private func configuration() -> USBScanner.Configuration {
        var configuration = USBScanner.Configuration(resolution: 150)
        configuration.firstSheetTimeout = .milliseconds(300)
        configuration.nextSheetTimeout = .milliseconds(50)
        configuration.pollInterval = .milliseconds(1)
        return configuration
    }

    private func pages(_ scanner: USBScanner) async throws -> [USBScanner.Page] {
        var pages: [USBScanner.Page] = []
        for try await page in await scanner.scan() { pages.append(page) }
        return pages
    }

    @Test func scansASheetUpright() async throws {
        // 70 lines: one full read of 68 lines, then a padded last read with end of medium.
        let device = SimulatedUSBScanner(sheets: [70])
        let pages = try await pages(USBScanner(channel: device, configuration: configuration()))
        #expect(pages.count == 1)
        let page = try #require(pages.first)
        #expect(page.width == 1274 && page.height == 70 && page.resolution == 150 && page.format == .rgb8)
        #expect(Array(page.data) == (await device.uprightPages)[0])
    }

    @Test func grayAndBlackAndWhitePagesAreMadeFromColour() async throws {
        var gray = configuration()
        gray.colorMode = .gray
        let grayDevice = SimulatedUSBScanner(sheets: [4])
        let grayPage = try #require(try await pages(USBScanner(channel: grayDevice, configuration: gray)).first)
        #expect(grayPage.format == .gray8 && grayPage.data.count == 1274 * 4)
        #expect(Array(grayPage.data) == PixelConversion.gray(fromRGB: (await grayDevice.uprightPages)[0]))

        var blackAndWhite = configuration()
        blackAndWhite.colorMode = .blackAndWhite(threshold: 100)
        let device = SimulatedUSBScanner(sheets: [4])
        let page = try #require(try await pages(USBScanner(channel: device, configuration: blackAndWhite)).first)
        // 1274 pixels need 160 bytes a line (159.25 rounded up).
        #expect(page.format == .blackAndWhite1 && page.data.count == 160 * 4)
        let expected = PixelConversion.blackAndWhite(fromGray: PixelConversion.gray(fromRGB: (await device.uprightPages)[0]),
                                                     width: 1274, threshold: 100)
        #expect(Array(page.data) == expected)
    }

    @Test func runsTheSetupBeforeFeedingAndEndsTheJob() async throws {
        let device = SimulatedUSBScanner(sheets: [10])
        _ = try await pages(USBScanner(channel: device, configuration: configuration()))
        let opcodes = await device.opcodes
        // After the sheet is loaded: feeder, pre-read, four MODE SELECTs, SET WINDOW, gamma, lamp, feed, SCAN.
        let feed = try #require(opcodes.firstIndex(of: 0x31))
        #expect(Array(opcodes[(feed - 9)...feed]) == [0xF1, 0x1D, 0x15, 0x15, 0x15, 0x15, 0x24, 0x2A, 0xF1, 0x31])
        #expect(opcodes[feed + 1] == 0x1B)
        // The end: another feed (no paper, 3/80/03), its sense, and MODE SELECT clearing the buffer.
        #expect(Array(opcodes.suffix(3)) == [0x31, 0x03, 0x15])
    }

    @Test func scansSeveralSheets() async throws {
        let device = SimulatedUSBScanner(sheets: [5, 8])
        let pages = try await pages(USBScanner(channel: device, configuration: configuration()))
        #expect(pages.map(\.index) == [0, 1])
        #expect(pages.map(\.height) == [5, 8])
    }

    @Test func cloudModeIsReportedAndTheScannerHalted() async throws {
        let device = SimulatedUSBScanner(sheets: [10])
        await device.setCloudMode(true)
        await #expect {
            _ = try await pages(USBScanner(channel: device, configuration: configuration()))
        } throws: { error in
            guard case ScannerError.paper(let sense) = error else { return false }
            return sense.paperProblem == .heldByCloudOrMobile
        }
        // Halt (31 04) and cancel (F1 04), then MODE SELECT.
        #expect(Array(await device.opcodes.suffix(3)) == [0x31, 0xF1, 0x15])
    }

    @Test func noSheetEndsWithAnError() async throws {
        let device = SimulatedUSBScanner(sheets: [])
        await #expect(throws: ScannerError.noSheet) {
            _ = try await pages(USBScanner(channel: device, configuration: configuration()))
        }
        // Nothing was set up, so nothing is halted.
        #expect(await device.opcodes.allSatisfy { $0 == 0x00 || $0 == 0xC2 })
    }

    @Test func aMissedFirstTransferIsRetried() async throws {
        let device = SimulatedUSBScanner(sheets: [3], failuresBeforeAnswering: 1)
        let pages = try await pages(USBScanner(channel: device, configuration: configuration()))
        #expect(pages.count == 1)
    }

    @Test func readInfo() async throws {
        let info = try await USBScanner(channel: SimulatedUSBScanner(sheets: []), configuration: configuration()).readInfo()
        #expect(info.hardwareStatus.count == 0x20)
    }
}
