# CLAUDE.md

Guidance for AI coding agents (and humans) working on scansnipswift: Swift packages for Fujitsu/Ricoh ScanSnap
scanners, for iOS, iPadOS and macOS apps, with no UI. Read README.md for the API,
docs/PROTOCOL-iX500-WiFi.md before touching Wi-Fi code, and docs/ROADMAP.md for what is next.

## Ground rules

- **This repository is public. Never commit anything personal:** scanner serial numbers (they are also in the
  Wi-Fi name, `iX500-<serial>`, and the last four characters are the factory Wi-Fi password), real IP or MAC
  addresses (use `192.0.2.x` and locally administered MACs such as `02:...`), host IDs read from a real
  scanner, host names, emails, or text from scanned documents.
- **Never commit scans or packet captures.** `.gitignore` blocks images, PDFs, pcaps, `scans/` and
  `captures/`. Test data is synthetic, built in code.
- **Hardware the maintainer owns: iX500 and iX100.** Do not claim support for other models. Anything not run
  on one of those two is "not yet checked on hardware", and docs must say so.
- **Licences.** Upstreams are MIT: [holgerkrupp/Scan](https://github.com/holgerkrupp/Scan) (Swift),
  [elte0/scansnack](https://github.com/elte0/scansnack) (Python) and
  [thomergil/open-scansnap](https://github.com/thomergil/open-scansnap) (Python; its `AGENTS.md` holds
  hardware-tested iX500 notes). Code adapted from any of them keeps the credit in LICENSE and a comment
  naming the file and upstream commit; facts taken from them are credited in a comment or the docs.
  - **Do not copy GPL code.** SANE's `fujitsu` backend, open-scansnap's SANE fork (branch `vens`, where its
    Wi-Fi and USB transport live) and [bramheerink/scansnap](https://github.com/bramheerink/scansnap) are
    GPL. Several of Scan's USB files are ports of SANE or copy its tables, so for Scan's
    `FujitsuSCSIOverUSB/` and `EpjitsuUSB/` folders take **facts only** (command bytes, offsets, quirks,
    observed behaviour) and write the code fresh.
  - The package stays MIT with no copyleft code, so closed-source apps can use it.
  - **No third-party dependencies.** Scan's USB layer links Homebrew's libusb (LGPL) and needs sandbox
    exceptions; this package must use Apple frameworks (IOUSBHost on macOS, DriverKit on iPadOS).

## Commands

```bash
swift build && swift test                       # macOS; no scanner needed
xcodebuild -scheme ScanSnip-Package -destination 'generic/platform=iOS Simulator' build
swift build --package-path Tools/scansnip       # the hardware-check tool
Tools/scansnip/.build/debug/scansnip scan <scanner IP> --trace [--dump <dir>]
```

`--trace` prints each command and the shape of each reply; `--dump` also saves raw image reads. For the demo
app: `cd Examples/ScanSnipDemo && xcodegen generate`, build with `-allowProvisioningUpdates`, install with
`xcrun devicectl device install app`, launch with `... process launch <bundle id> -- -scannerHost <ip>
-autoScan YES`, and read its log with `devicectl device copy from --domain-type appDataContainer --source
Documents/scansnip-log.txt`. Both stay
local: scans and dumps can hold documents, so keep them out of the repo.

## Layout

| Path | Role |
|---|---|
| `Sources/ScanSnipProtocol/VENS*.swift` | iX500 Wi-Fi wire format, no I/O: framing, discovery and notices, registration, SCSI-tunnel commands and scan parameters |
| `Sources/ScanSnipProtocol/SCSISense.swift` | Sense data and paper problems, shared by USB and Wi-Fi |
| `Sources/ScanSnipProtocol/ScanSnapModel.swift` | The models this package knows: USB IDs, duplex, Wi-Fi protocol |
| `Sources/ScanSnipProtocol/VENSiX100.swift` | iX100 scan settings, the sheet-loaded bit, joining multi-read pages |
| `Sources/ScanSnipScanner/` | The Wi-Fi client: transport protocols, Network.framework transport, discovery (`ScannerDiscovery`, BSD-socket `BroadcastBrowser`), the `WiFiScanner` actor |
| `Tests/ScanSnipScannerTests/SimulatedScanner.swift` | An in-memory iX100 that keeps the rules learned on hardware; extend it when a new one is found |
| `Tools/scansnip/` | A separate package: the command-line tool for checking against real scanners |
| `Examples/ScanSnipDemo/` | A SwiftUI demo app (XcodeGen `project.yml`); team and bundle ID only in the git-ignored `Config/Local.xcconfig` |
| `docs/PROTOCOL-iX500-WiFi.md` | Copy of ScanSnack's iX500 protocol notes, then open-scansnap's findings; our hardware findings go in its last section |
| `docs/PROTOCOL-iX100-WiFi.md` | Our own iX100 notes from hardware and an iOS-app capture |

## Scanner facts that cost time to learn (from the upstreams)

- **iX500 Wi-Fi pairing is USB-only.** The scanner's host table (the computers allowed on Wi-Fi) is written
  only over USB, with SEND DIAGNOSTIC commands (`CLR HOSTID ADATA`, then `REG HOSTID DATA `); pairing clears
  the table, so it evicts every other computer. An unknown host ID gets −7. ScanSnap Home's host ID for a
  Mac is its `en1` (else `en0`) MAC shifted left 16 bits (`VENS.hostID(mac:)`).
- **Mobile registrations skip the host table.** The ScanSnap iOS app registers with reserve mode 1 (body
  offset 4) and a zero host ID, and the scanner checks only the password (`Registrant.mobile`). Reserve mode
  0 without pairing gets −6. Checked on the iX100 (firmware 0V00); not yet on the iX500.
- **Register before any other control command, and always end a job.** The iX100 closes a status request
  sent before registering. A job released without `D6` leaves it answering −4 (busy) to everyone until it is
  power-cycled.
- **iX100: feed only a loaded sheet.** `C2` byte 3 bit 7 clears when a sheet reaches the slot; byte 2 bit 7
  sets once it is loaded. Feed on byte 2 (`VENS.iX100SheetReady`), as the iOS app does.
- **iX100: some blank sheets come back with no image** (a read of just the chunk header and end of medium),
  probably blank-page removal, though one nearly blank sheet scanned. It looked like a protocol bug for
  several rounds: test with marked sheets, and do not read an empty page as a client bug.
- **iX100: big pages come in several reads,** each after the first starting with 43 bytes to drop
  (`VENS.iX100ContinuationPrefixLength`); the chunk number stays 0.
- **Discovery without an address works on iOS.** Network.framework cannot broadcast, so `BroadcastBrowser` uses
  BSD sockets. A development build on iOS 27.2.1 broadcast without the multicast entitlement, though Apple
  documents that it is needed (request it before shipping); where a broadcast is refused or unanswered, the
  browser probes each address on the subnet (unicast needs no entitlement).
- **A low iX100 battery looks like a protocol bug.** At 6% it dropped sessions after 35-57 s. The status reply
  (`VENS.ControlStatus`, or `scansnip info`) gives the level; check it first.
- **iOS background:** about 30 s of `beginBackgroundTask` time; a suspended app cannot end a job, so stop with
  `stopAfterCurrentSheet()` while time remains (the demo app shows how).
- **Send each control command the moment the 16-byte greeting arrives.** An iX100 left waiting about a second
  closes the connection with no answer, which looks like a protocol error. It cost three wrong guesses.
- **The client MAC is the session identity, but need not be real.** A registration starts a reservation
  keyed to the frame's MAC; other MACs get −4 until it ends. The scanner accepts any MAC, so send a stable,
  locally administered one per host (macOS and iOS hide the real one).
- **Reservations expire.** Without heartbeats (`VENS.heartbeatFlag`, at least every 10 s) the scanner drops
  a reservation about 40 s after registration. Control command `0x12` releases it.
- **The Wi-Fi command set is not the USB one.** Wi-Fi uses vendor CDBs `C2 D5 D8 E9 D4 E0 28 D6` and rejects
  SET WINDOW, OBJECT POSITION, SCAN and the like (sense 5/20/00). USB uses Fujitsu's SCSI-over-USB set
  (SET WINDOW, OBJECT POSITION, READ, etc.) inside a 31-byte wrapper.
- The iX500 always scans colour and both sides; pages arrive as JPEGs rotated by 180°. The image index is one
  byte counting sides, so start a new job before 128 sheets (`VENS.maximumSheetsPerJob` is 120).
- A feed that reports "feeder empty" (3/80/03) is also how a job ends: check the hopper bit in the hardware
  status before telling the user the feeder is empty.
- End the job (`D6`) on a new connection once the scan connection is closed; it is not answered before.
  It ends the job, not the reservation.
- iX100: speaks the iX500's `VENS` Wi-Fi protocol, with its own scan settings (`VENS.iX100ParameterBlock`:
  80 bytes, or 128 with automatic colour) and sequence (no `E9`; `D6` answered on the scan connection). It
  crops pages, picks resolution and colour on automatic settings, and sends black and white as a G4 TIFF. See
  docs/PROTOCOL-iX100-WiFi.md.
- **iX100 over USB** (checked 2026-11-29): `04C5:13F4`, one vendor-class interface with bulk OUT `0x02` and bulk
  IN `0x81`, no driver attached, so IOUSBHost opens it from a plain process. The 31-byte command block and
  13-byte status work (INQUIRY and hardware status answered), but the Wi-Fi vendor commands are refused
  (`D9`, `E7`: sense 5/20/00), so USB scanning needs Fujitsu's SCSI set. Wi-Fi stays up while USB is plugged
  in. It did not enumerate at all through a Thunderbolt dock: plug it straight into the Mac.
- **Capturing the iOS app:** with the iPhone on USB, `rvictl -s <UDID>` (UDID from `xcrun devicectl list
  devices`) adds interface `rvi0`; the user runs `sudo tcpdump -i rvi0 -s 0 -w captures/<name>.pcap` (BPF
  needs root, and commands typed into a new Terminal-panel tab can be lost while fish starts). Scan a sheet
  with a pen mark (not a document; blank ones are removed), then `rvictl -x <UDID>`. Captures hold the serial
  and password: keep them in `captures/`.

## Conventions

- Swift 6 language mode, strict concurrency, no warnings. No third-party dependencies.
- Tests use Swift Testing. Add a check for any new parser, constant or byte layout, and break the code once
  to see the test fail. Work out expected bytes by hand or from the protocol notes, not by running the code.
- Keep the protocol layer pure (no sockets, no Foundation networking); transports and sessions go in a
  separate target.
