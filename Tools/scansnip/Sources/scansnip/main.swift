import Foundation
import ScanSnipProtocol
import ScanSnipScanner

let usage = """
    usage: scansnip discover <scanner address>
           scansnip scan <scanner address> [options]

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
    return "\(model) at \(ip), interface version \(a.interfaceVersion), "
        + "\(a.hasRegisteredHost ? "a host is registered" : "no host registered"); this Mac is \(local)"
}

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { print(usage); exit(2) }
let verb = arguments.removeFirst()
let network = NetworkTransport(host: arguments.removeFirst())
let dumpDirectory = option("--dump", in: arguments).map { URL(fileURLWithPath: $0) }
if let dumpDirectory { try? FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true) }
let transport: any VENSTransport = arguments.contains("--trace")
    ? TracingTransport(base: network, dumpDirectory: dumpDirectory) : network

do {
    switch verb {
    case "discover":
        print(describe(try await ScannerDiscovery.find(using: transport)))

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

        let scanner = try await ScannerDiscovery.find(using: transport)
        print(describe(scanner))
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
