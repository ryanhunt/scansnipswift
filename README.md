# scansnipswift

Open-source Swift packages for Fujitsu/Ricoh **ScanSnap** document scanners on iOS, iPadOS and macOS. Today it
has the iX500's Wi-Fi protocol as pure, tested wire formats. A Wi-Fi client, a USB transport and iX100 support
are next.

This is a library, not an app: it has no UI. Apps add it as a Swift package and build their own interface on
top.

> **Status: early.** Nothing here has been run against real hardware yet. The maintainer tests with a
> **ScanSnap iX500** and a **ScanSnap iX100**, so those are the only models this package aims to support.
> Other models may be added by people who own them. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Supported models

| Model | USB | Wi-Fi | Notes |
|---|---|---|---|
| iX500 (and iX500 EE) | planned | protocol ported (`VENS`), client planned | Duplex sheet feeder. Wi-Fi needs a one-time setup with ScanSnap Home over USB. |
| iX100 | planned | protocol undocumented | One sheet at a time, single-sided, battery. No open-source project drives it yet. |

## Packages

| Product | What it does |
|---|---|
| `ScanSnipProtocol` | Wire formats only, no I/O: the iX500 Wi-Fi protocol (`VENS`: discovery, notices, registration, the SCSI tunnel, scan parameters), SCSI sense data, and the model table (`ScanSnapModel`). |

Requires iOS 16 / macOS 13 or later and Swift 6.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/ryanhunt/scansnipswift.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "ScanSnipProtocol", package: "scansnipswift")]),
]
```

## Usage

The protocol layer builds and parses packets. It does not open sockets: the network client comes next
(see the roadmap).

```swift
import ScanSnipProtocol

// A UDP discovery probe for port 52217, and its reply.
let probe = VENS.probe(hostIP: myIPv4, hostMAC: myMAC, replyPort: replyPort)
if let scanner = VENS.Announcement(replyBytes), scanner.knownModel == .iX500 {
    print(scanner.name, scanner.ipAddress, scanner.hasRegisteredHost)

    // Register for a session on TCP 53219, reusing the host ID ScanSnap Home set up.
    let body = try VENS.registrationBody(
        interfaceVersion: scanner.interfaceVersion, hostIP: myIPv4,
        password: scanner.factoryPassword ?? userPassword, hostID: scanner.registeredHostID,
        date: .now, timeZone: .current)
    let frame = VENS.clientFrame(command: VENS.ControlCommand.register.rawValue, mac: myMAC, body: body)
}

// Scan settings for the SCSI tunnel on TCP 53218.
let settings = VENS.ScanParameters(resolution: 300, pageSize: .automatic, detectsDoubleFeed: true)
let setParameters = VENS.scsiFrame(mac: myMAC, cdb: VENS.Command.setParameters,
                                   output: VENS.parameterBlock(settings))
```

Things worth knowing (details in [docs/PROTOCOL-iX500-WiFi.md](docs/PROTOCOL-iX500-WiFi.md)):

- **Pairing happens over USB.** Only ScanSnap Home's Wi-Fi setup, over USB, adds a computer to the iX500's
  host table. A client reuses the host ID the scanner announces, and sends the MAC of the interface that
  reaches the scanner.
- **The iX500 always scans colour, both sides.** Grey, single-sided output, cropping and blank-page removal
  are done on the host. Pages arrive as JPEGs rotated by 180°.
- **One client at a time.** While ScanSnap Home or another computer holds the scanner, registration
  answers −4 (busy).

## Development

```bash
swift build && swift test
```

```bash
xcodebuild -scheme ScanSnip -destination 'generic/platform=iOS Simulator' build
```

The tests need no scanner. They check byte layouts against the published protocol notes, using
documentation addresses (192.0.2.x), locally administered MACs and made-up serial numbers.

## Credits and licence

MIT, see [LICENSE](LICENSE). This package stands on two MIT-licensed projects:

- **[holgerkrupp/Scan](https://github.com/holgerkrupp/Scan)** by Holger Krupp: a native macOS ScanSnap app in
  Swift. `ScanSnipProtocol`'s Wi-Fi code is adapted from its `VENSProtocol.swift` and tests, and its USB
  drivers are the main reference for the USB work to come.
- **[elte0/scansnack](https://github.com/elte0/scansnack)** by elte0: a Python client and eSCL bridge for
  ScanSnap scanners over Wi-Fi, which worked out the iX500 and iX1500 network protocols.
  [docs/PROTOCOL-iX500-WiFi.md](docs/PROTOCOL-iX500-WiFi.md) is copied from it.

Not affiliated with or endorsed by PFU, Fujitsu or Ricoh; ScanSnap is a trademark of PFU Limited.
