import Foundation
import ScanSnipProtocol
import ScanSnipScanner

let usage = """
    usage: scansnip discover [<scanner address>]
           scansnip scan [<scanner address>] [options]
           scansnip info [<scanner address>]       battery, firmware and page counts

    Without an address, discover searches the local networks (broadcast) and lists every scanner, and scan
    looks for the scanner it used last (remembered in ~/Library/Application Support/scansnip), then searches.
    discover --probe-subnet probes each address on the subnet instead of broadcasting.

    scan options:
      --color auto|color|gray|bw       colour mode (default auto)
      --resolution auto|150|200|300    (default auto)
      --paper auto|a4                  (default auto)
      --out <directory>                where pages go (default: the current directory)
      --password <password>            the scanner's password (default: the factory password)
      --next-sheet <seconds>           how long to wait for each further sheet (default 10)
      --trace                          print every command and the shape of each reply
      --dump <directory>               with --trace, also save each image read's raw data there

    Put a sheet in when asked. Supports the ScanSnap iX100. Never prints the serial number or password.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("scansnip: \(message)\n".utf8))
    exit(1)
}

/// The value after `name`, if given.
func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    return arguments[index + 1]
}

func describe(_ scanner: DiscoveredScanner) -> String {
    let a = scanner.announcement
    let model = a.knownModel.map { "\($0)" } ?? "\(a.model) (not supported)"
    let ip = a.ipAddress.map(String.init).joined(separator: ".")
    let local = scanner.localIPv4.map(String.init).joined(separator: ".")
    let how = switch scanner.method {
    case .address: "at its known address"
    case .broadcast: "by broadcast"
    case .subnetProbe: "by probing the subnet"
    }
    return "\(model) at \(ip), found \(how), interface version \(a.interfaceVersion), "
        + "\(a.hasRegisteredHost ? "a host is registered" : "no host registered"); this Mac is \(local)"
}

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { print(usage); exit(2) }
let verb = arguments.removeFirst()
let givenHost = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
if givenHost != nil { arguments.removeFirst() }
let dumpDirectory = option("--dump", in: arguments).map { URL(fileURLWithPath: $0) }
if let dumpDirectory { try? FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true) }

let tracing = arguments.contains("--trace")

@MainActor func makeTransport(_ host: String) -> any VENSTransport {
    let network = NetworkTransport(host: host)
    return tracing ? TracingTransport(base: network, dumpDirectory: dumpDirectory) : network
}

/// The scanner used last, kept on this Mac only (its name holds the serial number).
let memoryFile = URL.applicationSupportDirectory.appending(path: "scansnip/scanner.json")

func rememberedScanner() -> RememberedScanner? {
    (try? Data(contentsOf: memoryFile)).flatMap { try? JSONDecoder().decode(RememberedScanner.self, from: $0) }
}

func remember(_ scanner: DiscoveredScanner) {
    try? FileManager.default.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(scanner.remembered).write(to: memoryFile)
}

do {
    switch verb {
    case "info":
        let scanner = if let host = givenHost {
            try await ScannerDiscovery.find(using: makeTransport(host))
        } else {
            try await ScannerDiscovery.locate(remembered: rememberedScanner())
        }
        print(describe(scanner))
        remember(scanner)
        let client = WiFiScanner(transport: makeTransport(scanner.host), scanner: scanner,
                                 configuration: .init(clientMAC: WiFiScanner.Configuration.randomClientMAC()))
        let info = try await client.readInfo()
        if let inquiry = info.inquiry {
            print("product: \(inquiry.vendor) \(inquiry.product), firmware \(inquiry.revision)")
        }
        if let status = info.status {
            let battery = status.batteryPercent.map { "\($0)%\(status.batteryLow ? " (low)" : "")" } ?? "no battery reported"
            print("battery: \(battery); status word \(status.word)")
        }
        if let counters = info.counters {
            print("pages scanned: \(counters.pages)"
                  + (counters.others.isEmpty ? "" : "; other counters: \(counters.others.map(String.init).joined(separator: ", "))"))
        }

    case "discover":
        if let host = givenHost {
            print(describe(try await ScannerDiscovery.find(using: makeTransport(host))))
        } else {
            let browser = BroadcastBrowser(alwaysProbeSubnet: arguments.contains("--probe-subnet"))
            let found = try await browser.browse(timeout: .seconds(5))
            if found.isEmpty { print("No scanner answered.") }
            for scanner in found { print(describe(scanner)) }
        }

    case "scan":
        var parameters = VENS.IX100ScanParameters()
        switch option("--color", in: arguments) ?? "auto" {
        case "auto": parameters.colorMode = .automatic
        case "color": parameters.colorMode = .color
        case "gray": parameters.colorMode = .gray
        case "bw": parameters.colorMode = .blackAndWhite
        case let other: fail("unknown colour mode \(other)")
        }
        switch option("--resolution", in: arguments) ?? "auto" {
        case "auto": parameters.resolution = .automatic
        case "150": parameters.resolution = .dpi150
        case "200": parameters.resolution = .dpi200
        case "300": parameters.resolution = .dpi300
        case let other: fail("unknown resolution \(other)")
        }
        switch option("--paper", in: arguments) ?? "auto" {
        case "auto": parameters.pageSize = .automatic
        case "a4": parameters.pageSize = .a4
        case let other: fail("unknown paper size \(other)")
        }
        let directory = URL(fileURLWithPath: option("--out", in: arguments) ?? ".")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scanner = if let host = givenHost {
            try await ScannerDiscovery.find(using: makeTransport(host))
        } else {
            try await ScannerDiscovery.locate(remembered: rememberedScanner())
        }
        print(describe(scanner))
        remember(scanner)
        let transport = makeTransport(scanner.host)
        var configuration = WiFiScanner.Configuration(clientMAC: WiFiScanner.Configuration.randomClientMAC(),
                                                      password: option("--password", in: arguments))
        if let seconds = option("--next-sheet", in: arguments) {
            guard let value = Double(seconds) else { fail("--next-sheet needs a number of seconds") }
            configuration.nextSheetTimeout = .milliseconds(Int(value * 1000))
        }
        let client = WiFiScanner(transport: transport, scanner: scanner, configuration: configuration)
        print("Put a sheet in the scanner.")
        let stamp = Int(Date().timeIntervalSince1970)
        let pages = await client.scan(parameters)
        // The scan runs as a task, so Ctrl-C or a failed write can cancel it; the tool then waits for the
        // library to end the job and release the scanner before exiting (an iX100 left mid-job stays busy).
        let scanTask = Task { () throws -> Int in
            var count = 0
            for try await page in pages {
                let name = String(format: "scan-%d-%03d.%@", stamp, page.index + 1, page.format == .tiff ? "tif" : "jpg")
                try page.data.write(to: directory.appendingPathComponent(name))
                count += 1
                print("page \(page.index + 1): \(page.data.count) bytes, \(name). Put in another sheet, or wait to finish.")
            }
            return count
        }
        signal(SIGINT, SIG_IGN)
        let interrupted = Counter()
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            print("stopping: ending the job and releasing the scanner")
            _ = interrupted.next()
            scanTask.cancel()
        }
        interrupt.resume()
        let result = await scanTask.result
        await client.waitUntilIdle()
        interrupt.cancel()
        let count = try result.get()
        let skipped = await client.blankPagesSkipped
        let verb = interrupted.next() > 1 ? "stopped" : "done"
        print("\(verb): \(count) page\(count == 1 ? "" : "s")"
              + (skipped > 0 ? ", \(skipped) blank sheet\(skipped == 1 ? "" : "s") skipped (no image came back)" : ""))

    default:
        print(usage)
        exit(2)
    }
} catch let error as ScannerError {
    fail("\(error)")
} catch {
    fail("\(error)")
}
