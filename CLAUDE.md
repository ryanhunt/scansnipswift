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
- **Licences.** Upstreams are MIT: [holgerkrupp/Scan](https://github.com/holgerkrupp/Scan) (Swift) and
  [elte0/scansnack](https://github.com/elte0/scansnack) (Python). Code adapted from either keeps the credit
  in LICENSE and a comment naming the file and upstream commit.
  - **Do not copy GPL code.** SANE's `fujitsu` backend and [bramheerink/scansnap](https://github.com/bramheerink/scansnap)
    are GPL. Several of Scan's USB files are ports of SANE or copy its tables, so for Scan's
    `FujitsuSCSIOverUSB/` and `EpjitsuUSB/` folders take **facts only** (command bytes, offsets, quirks,
    observed behaviour) and write the code fresh.
  - **No third-party dependencies.** Scan's USB layer links Homebrew's libusb (LGPL) and needs sandbox
    exceptions; this package must use Apple frameworks (IOUSBHost on macOS, DriverKit on iPadOS).

## Commands

```bash
swift build && swift test                       # macOS; no scanner needed
xcodebuild -scheme ScanSnip -destination 'generic/platform=iOS Simulator' build
```

Once the package has more than one product the Xcode scheme becomes `ScanSnip-Package`; update CI too.

## Layout

| Path | Role |
|---|---|
| `Sources/ScanSnipProtocol/VENS*.swift` | iX500 Wi-Fi wire format, no I/O: framing, discovery and notices, registration, SCSI-tunnel commands and scan parameters |
| `Sources/ScanSnipProtocol/SCSISense.swift` | Sense data and paper problems, shared by USB and Wi-Fi |
| `Sources/ScanSnipProtocol/ScanSnapModel.swift` | The models this package knows: USB IDs, duplex, Wi-Fi protocol |
| `docs/PROTOCOL-iX500-WiFi.md` | Copy of ScanSnack's iX500 protocol notes; our hardware findings go in its last section |

## Scanner facts that cost time to learn (from the upstreams)

- **iX500 Wi-Fi pairing is USB-only.** Only ScanSnap Home's Wi-Fi setup over USB writes the scanner's host
  table. A client reuses the host ID from the discovery reply (offset 124); an unknown ID gets −7.
- **The client MAC is the session identity.** The scan channel only answers the MAC that sent the last
  registration. iOS does not expose the device's real MAC, so whether iOS can drive the iX500 over Wi-Fi is
  an open question (spike it before building on it).
- **The Wi-Fi command set is not the USB one.** Wi-Fi uses vendor CDBs `C2 D5 D8 E9 D4 E0 28 D6`. USB uses
  Fujitsu's SCSI-over-USB set (SET WINDOW, OBJECT POSITION, READ, etc.) inside a 31-byte wrapper.
- The iX500 always scans colour and both sides; pages arrive as JPEGs rotated by 180°. The image index is one
  byte counting sides, so start a new job before 128 sheets (`VENS.maximumSheetsPerJob` is 120).
- A feed that reports "feeder empty" (3/80/03) is also how a job ends: check the hopper bit in the hardware
  status before telling the user the feeder is empty.
- Release (`D6`) is answered only after the scan connection is closed; send it on a new connection.
- iX100: USB ID `04C5:13F4` (from Scan's tests, not yet checked). Scan leaves it unclaimed on purpose (Ricoh
  still supports it); SANE drives it like an iX500 without duplex. Its Wi-Fi protocol is undocumented.

## Conventions

- Swift 6 language mode, strict concurrency, no warnings. No third-party dependencies.
- Tests use Swift Testing. Add a check for any new parser, constant or byte layout, and break the code once
  to see the test fail. Work out expected bytes by hand or from the protocol notes, not by running the code.
- Keep the protocol layer pure (no sockets, no Foundation networking); transports and sessions go in a
  separate target.
