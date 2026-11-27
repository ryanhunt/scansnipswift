import Foundation
import ScanSnipProtocol
import ScanSnipScanner
import UIKit

/// Finds a ScanSnap at the address the user gives and scans from it with `WiFiScanner`.
///
/// Launch arguments (handy from `xcrun devicectl device process launch ... -- <args>`):
/// `-scannerHost 192.0.2.20` sets the address, `-autoScan YES` starts a scan at launch.
/// The log is also written to Documents/scansnip-log.txt.
@MainActor
final class ScanModel: ObservableObject {
    struct ScannedPage: Identifiable {
        let id = UUID()
        let index: Int
        let format: WiFiScanner.PageFormat
        let image: UIImage?
        let byteCount: Int
    }

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "scannerHost") }
    }
    @Published var colorMode: VENS.IX100ScanParameters.ColorMode = .automatic
    @Published private(set) var log: [String] = []
    @Published private(set) var pages: [ScannedPage] = []
    @Published private(set) var busy = false

    private var scanTask: Task<Void, Never>?
    private let started = Date()
    private let logFile = URL.documentsDirectory.appending(path: "scansnip-log.txt")

    /// A stable, locally administered MAC for this install: the scanner keys its session to it.
    private let clientMAC: [UInt8] = {
        if let saved = UserDefaults.standard.data(forKey: "clientMAC"), saved.count == 6 { return Array(saved) }
        let mac = WiFiScanner.Configuration.randomClientMAC()
        UserDefaults.standard.set(Data(mac), forKey: "clientMAC")
        return mac
    }()

    init() {
        host = UserDefaults.standard.string(forKey: "scannerHost") ?? ""
        try? Data().write(to: logFile)
        write("ScanSnip Demo started")
    }

    var autoScan: Bool { UserDefaults.standard.bool(forKey: "autoScan") }

    func scan() {
        guard !busy else { return }
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return write("Enter the scanner's IP address first.") }
        busy = true
        UIApplication.shared.isIdleTimerDisabled = true
        let mode = colorMode
        scanTask = Task {
            await run(host: host, mode: mode)
            busy = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func stop() {
        write("Stopping: ending the job and releasing the scanner")
        scanTask?.cancel()
    }

    private func run(host: String, mode: VENS.IX100ScanParameters.ColorMode) async {
        // A long connect timeout: the first connection waits while iOS shows the local-network alert.
        let transport = NetworkTransport(host: host, connectTimeout: .seconds(60))
        write("Finding the scanner at \(host)")
        let scanner: DiscoveredScanner
        do {
            scanner = try await ScannerDiscovery.find(using: transport, timeout: .seconds(60))
        } catch {
            return write("Not found: \(error)")
        }
        let announcement = scanner.announcement
        write("Found \(announcement.model) (interface \(announcement.interfaceVersion)); "
              + "this device is \(scanner.localIPv4.map(String.init).joined(separator: "."))")
        guard scanner.model?.wiFi == .vens, scanner.model == .iX100 else {
            return write("Only the iX100 is supported so far.")
        }

        var configuration = WiFiScanner.Configuration(clientMAC: clientMAC)
        configuration.nextSheetTimeout = .seconds(15)
        let client = WiFiScanner(transport: transport, scanner: scanner, configuration: configuration)
        write("Put a sheet in the scanner (\(mode))")
        do {
            for try await page in await client.scan(.init(colorMode: mode)) {
                let image = UIImage(data: page.data)
                let size = image.map { "\(Int($0.size.width * $0.scale))×\(Int($0.size.height * $0.scale))" } ?? "?"
                let name = String(format: "page-%03d.%@", page.index + 1, page.format == .tiff ? "tif" : "jpg")
                try? page.data.write(to: URL.documentsDirectory.appending(path: name))
                pages.append(ScannedPage(index: page.index, format: page.format, image: image,
                                         byteCount: page.data.count))
                write("Page \(page.index + 1): \(page.format == .tiff ? "TIFF" : "JPEG"), \(page.data.count) bytes, "
                      + "\(size). Put in another sheet, or wait to finish.")
            }
            let blanks = await client.blankPagesSkipped
            write("Done" + (blanks > 0 ? "; \(blanks) blank sheet(s) skipped (no image came back)" : ""))
        } catch {
            write("Scan ended: \(error)")
        }
        await client.waitUntilIdle()
        write("Scanner released")
    }

    private func write(_ line: String) {
        let stamped = String(format: "[%6.1f] ", Date().timeIntervalSince(started)) + line
        log.append(stamped)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data((stamped + "\n").utf8))
            try? handle.close()
        }
    }
}
