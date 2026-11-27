import Foundation
import ScanSnipProtocol
import ScanSnipScanner
import UIKit

/// Finds a ScanSnap and scans from it with `WiFiScanner`. It remembers the scanner it used last and looks there
/// first; with no address, or if the scanner is not there any more, it searches the local network.
///
/// Launch arguments (handy from `xcrun devicectl device process launch ... -- <args>`):
/// `-scannerHost 192.0.2.20` sets the address, `-forgetScanner YES` forgets the remembered scanner,
/// `-autoScan YES` starts a scan at launch. The log is also written to Documents/scansnip-log.txt.
@MainActor
final class ScanModel: ObservableObject {
    struct ScannedPage: Identifiable {
        let id = UUID()
        let index: Int
        let format: WiFiScanner.PageFormat
        let image: UIImage?
        let byteCount: Int
    }

    /// The address to try first; filled in from the remembered scanner, and editable.
    @Published var host: String
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

    /// The scanner found last (its name holds the serial number, so it stays on this device and out of logs).
    private var remembered: RememberedScanner? {
        get {
            UserDefaults.standard.data(forKey: "rememberedScanner")
                .flatMap { try? JSONDecoder().decode(RememberedScanner.self, from: $0) }
        }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "rememberedScanner") }
    }

    init() {
        host = ""
        try? Data().write(to: logFile)
        write("ScanSnip Demo started")
        if UserDefaults.standard.bool(forKey: "forgetScanner") {
            remembered = nil
            UserDefaults.standard.removeObject(forKey: "scannerHost")  // saved by an earlier version of the demo
            write("Forgot the remembered scanner")
        }
        host = UserDefaults.standard.string(forKey: "scannerHost") ?? remembered?.host ?? ""
    }

    var autoScan: Bool { UserDefaults.standard.bool(forKey: "autoScan") }

    func scan() {
        guard !busy else { return }
        let host = host.trimmingCharacters(in: .whitespaces)
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

    /// Lists every scanner on the local network, and picks the first supported one.
    func search() {
        guard !busy else { return }
        busy = true
        scanTask = Task {
            write("Searching the local network")
            do {
                let found = try await BroadcastBrowser().browse(timeout: .seconds(8))
                if found.isEmpty { write("No scanner answered") }
                for scanner in found { write("Found \(scanner.announcement.model) at \(scanner.host) \(how(scanner))") }
                if let first = found.first(where: { $0.model == .iX100 }) {
                    remembered = first.remembered
                    host = first.host
                }
            } catch {
                write("Search failed: \(error)")
            }
            busy = false
        }
    }

    private func how(_ scanner: DiscoveredScanner) -> String {
        switch scanner.method {
        case .address: "at the remembered address"
        case .broadcast: "by broadcast"
        case .subnetProbe: "by probing each address (broadcast was refused)"
        }
    }

    private func run(host: String, mode: VENS.IX100ScanParameters.ColorMode) async {
        // The typed address first (with the remembered name if it is the same scanner), then a search.
        let saved = remembered
        let start = host.isEmpty ? saved : RememberedScanner(host: host, name: saved?.host == host ? saved?.name : nil)
        write(start == nil ? "Searching the local network for a scanner" : "Looking at \(host), then on the local network")
        let scanner: DiscoveredScanner
        do {
            // A long connect timeout for the address itself: the first connection waits while iOS shows the
            // local-network alert. locate() still gives up on that address after 6 s and searches instead.
            scanner = try await ScannerDiscovery.locate(
                remembered: start, addressTimeout: .seconds(6), browseTimeout: .seconds(10),
                transport: { NetworkTransport(host: $0, connectTimeout: .seconds(60)) })
        } catch {
            return write("Not found: \(error)")
        }
        remembered = scanner.remembered
        self.host = scanner.host
        let announcement = scanner.announcement
        write("Found \(announcement.model) at \(scanner.host) \(how(scanner)); "
              + "this device is \(scanner.localIPv4.map(String.init).joined(separator: "."))")
        let transport = NetworkTransport(host: scanner.host, connectTimeout: .seconds(60))
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
