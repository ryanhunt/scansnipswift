# scansnipswift

Open-source Swift packages for Fujitsu/Ricoh **ScanSnap** document scanners on iOS, iPadOS and macOS. It has the
Wi-Fi protocol the iX500 and iX100 share, as pure tested wire formats, and a Wi-Fi client that scans from the
iX100. A USB transport is next.

This is a library, not an app: it has no UI. Apps add it as a Swift package and build their own interface on
top.

> **Status: early.** On hardware so far: the iX100 over Wi-Fi, scanning through `ScanSnipScanner` from a Mac
> (automatic, colour, grey and black-and-white pages, and pages larger than one read). Not yet run from an
> iPhone or iPad, and the client does not drive the iX500 yet. The maintainer tests with a
> **ScanSnap iX500** and a **ScanSnap iX100**, so those are the only models this package aims to support.
> Other models may be added by people who own them. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Supported models

| Model | USB | Wi-Fi | Notes |
|---|---|---|---|
| iX500 (and iX500 EE) | planned | protocol ported (`VENS`); the client does not support it yet | Duplex sheet feeder. Macs pair once over USB (ScanSnap Home does it); phones use the password. |
| iX100 | planned | scans with `WiFiScanner` (checked from a Mac) | One sheet at a time, single-sided, battery. [Notes](docs/PROTOCOL-iX100-WiFi.md). |

## Packages

| Product | What it does |
|---|---|
| `ScanSnipProtocol` | Wire formats only, no I/O: the Wi-Fi protocol of the iX500 and iX100 (`VENS`: discovery, notices, registration, the SCSI tunnel, scan parameters for each model), SCSI sense data, and the model table (`ScanSnapModel`). |
| `ScanSnipScanner` | Talks to a scanner over Wi-Fi with Network.framework: `ScannerDiscovery` finds it at an address, `WiFiScanner` scans pages. iX100 only for now. |

Requires iOS 16 / macOS 13 or later and Swift 6.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/ryanhunt/scansnipswift.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "ScanSnipScanner", package: "scansnipswift")]),
]
```

## Usage

```swift
import ScanSnipProtocol
import ScanSnipScanner

let transport = NetworkTransport(host: "192.0.2.20")           // the scanner's address
let scanner = try await ScannerDiscovery.find(using: transport)  // waits for a sleeping scanner to answer
let client = WiFiScanner(transport: transport, scanner: scanner,
                         configuration: .init(clientMAC: savedClientMAC))  // randomClientMAC() once, then keep it
for try await page in await client.scan(.init(colorMode: .automatic)) {
    try page.data.write(to: folder.appendingPathComponent("page-\(page.index).\(page.format == .tiff ? "tif" : "jpg")"))
}
print("blank sheets removed by the scanner:", await client.blankPagesSkipped)
```

`scan` waits for a sheet, scans each one put in until none comes within `nextSheetTimeout`, and always ends
the job and releases the scanner, even after an error or when you stop iterating. On iOS, add
`NSLocalNetworkUsageDescription` to your Info.plist; a refused local-network permission shows up as
`ScannerError.network`.

The protocol layer underneath builds and parses packets without opening sockets:

```swift
import ScanSnipProtocol

// A UDP discovery probe for port 52217, and its reply. `clientMAC` is any stable, locally administered
// MAC: the scanner keys the session to it and does not check it against the real one.
let probe = VENS.probe(hostIP: myIPv4, hostMAC: clientMAC, replyPort: replyPort)
if let scanner = VENS.Announcement(replyBytes), scanner.knownModel?.wiFi == .vens {
    print(scanner.name, scanner.ipAddress, scanner.hasRegisteredHost)

    // Register on TCP 53219 the way the ScanSnap iOS app does: the password alone, no pairing. Send it as
    // soon as the scanner's 16-byte greeting arrives. (A Mac paired by ScanSnap Home can instead register
    // as `.pairedHost(hostID: VENS.hostID(mac: en1MAC))`.)
    let body = try VENS.registrationBody(
        interfaceVersion: scanner.interfaceVersion, hostIP: myIPv4,
        password: scanner.factoryPassword ?? userPassword, registrant: .mobile, date: .now, timeZone: .current)
    let frame = VENS.clientFrame(command: VENS.ControlCommand.register.rawValue, mac: clientMAC, body: body)
}

// Scan settings for the SCSI tunnel on TCP 53218.
let settings = VENS.ScanParameters(resolution: 300, pageSize: .automatic, detectsDoubleFeed: true)
let setParameters = VENS.scsiFrame(mac: clientMAC, cdb: VENS.Command.setParameters,
                                   output: VENS.parameterBlock(settings))
```

Things worth knowing (details in [docs/PROTOCOL-iX500-WiFi.md](docs/PROTOCOL-iX500-WiFi.md) and
[docs/PROTOCOL-iX100-WiFi.md](docs/PROTOCOL-iX100-WiFi.md)):

- **No pairing needed for a mobile registration.** The ScanSnap iOS app registers with reserve mode 1 and
  no host ID (`Registrant.mobile`), and the scanner checks only the password. Checked on the iX100 from a
  Mac and an iPhone; not yet on the iX500.
- **Paired hosts are set up over USB.** Only USB commands add a computer to the iX500's host table, and
  pairing removes every other computer. ScanSnap Home's host ID for a Mac is its `en1` MAC shifted left 16
  bits (`VENS.hostID(mac:)`).
- **Answer the greeting at once.** Each control command gets its own connection; send it as soon as the
  16-byte greeting arrives, or the iX100 closes the connection without answering.
- **Sessions expire.** Send a heartbeat probe (`VENS.heartbeatFlag`) at least every 10 seconds, or the
  scanner drops the session about 40 seconds after registering. `VENS.ControlCommand.release` ends it.
- **The iX500 always scans colour, both sides.** Grey, single-sided output, cropping and blank-page removal
  are done on the host. Pages arrive as JPEGs rotated by 180°. The iX100 does more itself: it crops the page,
  picks the resolution and colour on automatic settings (`VENS.IX100ScanParameters`), and sends black and
  white as a Group 4 TIFF.
- **One client at a time.** While ScanSnap Home or another computer holds the scanner, registration
  answers −4 (busy).
- **The iX100 removes blank sheets.** A sheet with nothing on it produces no page (`blankPagesSkipped`), so
  test with sheets that have some marking on them.
- **Feed only a loaded sheet.** The iX100's hardware status shows a sheet at the slot (byte 3) before it is
  loaded (byte 2, `VENS.iX100SheetReady`); `WiFiScanner` waits for the second, as the iOS app does.

## Development

```bash
swift build && swift test
```

```bash
xcodebuild -scheme ScanSnip-Package -destination 'generic/platform=iOS Simulator' build
```

The tests need no scanner. They check byte layouts against the published protocol notes and run the client
against a simulated iX100 that behaves as the real one did, using documentation addresses (192.0.2.x),
locally administered MACs and made-up serial numbers.

To try a real scanner from a Mac, build the `scansnip` tool (its own package, so this one stays library-only):

```bash
swift build --package-path Tools/scansnip
```

```bash
Tools/scansnip/.build/debug/scansnip scan 192.0.2.20 --color auto --out ~/Desktop/scans --trace
```

`--trace` prints every command and the shape of each reply (never the password or image data).

## Credits and licence

MIT, see [LICENSE](LICENSE). It contains no GPL or LGPL code, so closed-source apps can use it; ship
the LICENSE text with your app. This package stands on three MIT-licensed projects:

- **[holgerkrupp/Scan](https://github.com/holgerkrupp/Scan)** by Holger Krupp: a native macOS ScanSnap app in
  Swift. `ScanSnipProtocol`'s Wi-Fi code is adapted from its `VENSProtocol.swift` and tests, and its USB
  drivers are the main reference for the USB work to come.
- **[elte0/scansnack](https://github.com/elte0/scansnack)** by elte0: a Python client and eSCL bridge for
  ScanSnap scanners over Wi-Fi, which worked out the iX500 and iX1500 network protocols.
  [docs/PROTOCOL-iX500-WiFi.md](docs/PROTOCOL-iX500-WiFi.md) is copied from it.
- **[thomergil/open-scansnap](https://github.com/thomergil/open-scansnap)** by Thomer Gil: a macOS menu-bar
  app that scans from the iX500 over Wi-Fi and USB. Its hardware-tested notes on host IDs, sessions, pairing
  and Wi-Fi setup over USB are summarised in the protocol notes, and `VENS.Command` uses the command names
  it recorded.

Not affiliated with or endorsed by PFU, Fujitsu or Ricoh; ScanSnap is a trademark of PFU Limited.
