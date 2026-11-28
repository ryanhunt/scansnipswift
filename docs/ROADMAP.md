# Roadmap

Scope: the ScanSnap **iX500** and **iX100**, the models the maintainer can test. Apps own the UI, storage,
OCR and PDF assembly; this package supplies what talks to the scanner and what turns its output into pages.

**[HW]** marks work that needs a real scanner.

## Done

- **iX500 Wi-Fi protocol** (`ScanSnipProtocol`): frames, discovery and heartbeat probes, the discovery
  reply, notices, password encoding, registration body and status, the host ID, the release command, the SCSI
  tunnel, scan commands, window and parameter blocks with page sizes, image chunk headers, the hopper bit.
  Adapted from holgerkrupp/Scan (`VENSProtocol.swift`, 413a7e5), checked against ScanSnack's
  `docs/protocol-ix500.md` (cf3464f), with command names and session facts from open-scansnap's `AGENTS.md`
  (ac26f6f).
- **SCSI sense** parsing and paper problems.
- **Model table** with USB IDs for the iX500, iX500 EE and iX100.
- **iX100 scan settings:** `VENS.iX100ParameterBlock` for automatic, colour, grey and black-and-white,
  150/200/300 dpi and A4, matched byte for byte against the iOS app's blocks.
- **Wi-Fi client for the iX100 [HW]** (`ScanSnipScanner`): Network.framework transport, discovery at a known
  address, `WiFiScanner` (mobile registration, heartbeats, one job per loaded sheet, multi-read pages,
  sheets that come back empty, always ending the job and releasing), a simulated iX100 for tests, and the
  `scansnip` tool. Checked from a Mac on 2026-11-27.
- **Background scanning, iPad, scanner info [HW]:** on iOS a scan keeps going in the ~30 s of background time
  the app asks for, a page in progress completes, and `stopAfterCurrentSheet()` ends it cleanly before
  suspension; the demo ran on an iPad Pro (iPadOS 27.2.1); `readInfo()` reads battery, firmware and page
  counts; `Configuration.onProgress` reports each step. 2026-11-28 and 29.
- **Discovery without an address [HW]:** `BroadcastBrowser` (BSD-socket broadcast, probing each address
  where a broadcast is refused) and `ScannerDiscovery.locate` with `RememberedScanner` (last address first,
  then a search, matched by name). Checked from the Mac (broadcast, one-by-one probing, remembered address)
  and the iPhone (broadcast without the multicast entitlement, remembered address), 2026-11-28.
- **iOS spike [HW]:** `Examples/ScanSnipDemo`, a SwiftUI app on `ScanSnipScanner`, found the iX100 at its
  address and scanned a page on an iPhone 15 Pro Max (iOS 27.2.1, 2026-11-27), with local-network access
  allowed: no pairing, no real MAC, no entitlement needed for a known address.
- **First scans from a Mac [HW]:** automatic, colour, grey and black-and-white pages from the iX100 through
  `ScanSnipProtocol` alone (a throwaway tool), each matching the iOS app's image.
- **iX100 over Wi-Fi, first look [HW]:** it answers `VENS` discovery and accepts mobile registrations
  (`Registrant.mobile`, password only); a capture of the ScanSnap iOS app gave its scan sequence. See
  `docs/PROTOCOL-iX100-WiFi.md`.
- CI: `swift test` on macOS and an iOS Simulator build.

## Next

1. **Hardware check of what exists [HW].** On the iX500 (once it is back on the desk): capture a discovery
   reply and a registration (redact serial, MAC, host ID and IP) and compare them with the parsers; check
   that a mobile registration is accepted, that `VENS.hostID(mac:)` from en1 is accepted, and that a made-up
   client MAC works; time how long a reservation lasts without heartbeats. On both scanners: confirm the USB
   product IDs with `system_profiler SPUSBHostDataType`. Record results in
   `docs/PROTOCOL-iX500-WiFi.md` ("Notes from scansnipswift").
2. **Wi-Fi client, the rest:** the iX500's scan sequence (two sides, `E9`, image information, `D6` on a new
   connection) once it is back on the desk; registering as a paired host (`VENS.hostID`) for
   Macs paired by ScanSnap Home; whether a `D4` byte controls the empty blank-sheet reads (capture the app
   with blank-page removal off); a `status` command in `scansnip`.
3. **iOS, the rest:** whether a TestFlight or App Store build can broadcast without the multicast
   entitlement. Apple documents that it cannot (Apple DTS: "sending or receiving multicast or broadcast traffic
   requires the multicast entitlement", enforced for BSD sockets since iOS 16), yet a development build on iOS
   27.2.1 could. Request the entitlement before shipping broadcast discovery; the remembered address and the
   one-by-one probe work without it. Also CI building the demo app.
4. **USB transport on macOS** (IOUSBHost, no libusb) **[HW]**: the 31-byte command wrapper (byte 0 `0x43`,
   CDB at 0x13), 13-byte status, REQUEST SENSE on a non-zero status, and the iX500 command sequence (SET
   WINDOW, gamma and JPEG tables, OBJECT POSITION, START SCAN, READ per side). Facts from Scan's
   `FujitsuSCSIOverUSB/` and SANE's documentation; **write the code fresh**, since parts of Scan's USB layer
   are GPL-derived. Hardware JPEG gives one stream per side on the iX500.
5. **iX100 over USB [HW]:** done for colour on macOS (`USBScanner`, checked 2026-11-29 at 150 dpi). Grey and
   black and white are made from colour on the device (as Scan does for the iX500); not yet checked on
   hardware. Next: check them and the other resolutions on hardware, several sheets in one scan, the scanner's
   own grey and line-art modes, reading the VPD page for the scanner's limits, switching ScanSnap Cloud mode off from the library (needs a USB capture of ScanSnap Home; see
   docs/CAPTURING-USB.md),
   and iPadOS through DriverKit.
6. **Pairing and Wi-Fi setup [HW]:** over USB, SEND DIAGNOSTIC with 16-byte ASCII commands (`CLR HOSTID
   ADATA`, `REG HOSTID DATA `, `SETUP NET …`), per open-scansnap's notes; over Wi-Fi, control command 0x40
   carries the same setup commands (ScanSnap Manager has parallel USB and network versions of each). Pairing
   with `CLR` first removes every other computer, so the API must say so; whether `REG` alone adds to the
   table (room for 31) is open. Lets an app pair a Mac without ScanSnap Home, and lets an iPhone set up an
   iX100 through its own network, iOS having no USB. A wrong network or key cuts the scanner off, so go in
   stages and **never try opcodes blind** (the opcode space includes resets and mode changes):
   1. Read only, over USB: the host table, then a `SETUP NET` session reading opcodes 0x0A, 7 and 6
      (always send `SETUP NET END`). Then the same reads over 0x40 on the iX100.
   2. Captures of the ScanSnap iOS app's Wi-Fi setup and the Mac Wi-Fi tool (viewing the settings,
      re-applying the same network, starting and cancelling WPS, changing the mode), for the layouts.
   3. The first write over USB, cable attached: re-apply the settings read in step 1.
   4. On the iX500: read the host table, `REG` without `CLR`, read it again, restore it.
7. **Scan button:** UDP notices over Wi-Fi (`VENS.Notice`), hardware-status polling over USB (byte 4, mask
   0x21 on the iX500, per Scan).

## Later

- **Page finishing** in a separate target: rotate the iX500's Wi-Fi pages by 180°, drop backs for
  single-sided output, blank-page detection, grey and black-and-white conversion, deskew and crop. These are
  host-side on the iX500.
- **iPadOS USB** via DriverKit.
- **eSCL/AirScan bridge**, as ScanSnack does (ADR 0001 there), so other apps can scan through this package.

## Other models

Not yet checked on hardware: each needs an owner to test it before the package claims support. USB IDs are
vendor `04C5` unless noted, from SANE's model list and holgerkrupp/Scan; the families from those and from the
names in ScanSnap Manager 7.2.70's files.

| Model | USB ID | USB commands | Wi-Fi | What it would take |
|---|---|---|---|---|
| iX500 EE | `13F3` | Fujitsu SCSI, as the iX500 | none known | The iX500's USB path |
| iX1300 | `162C` | Fujitsu SCSI | unknown dialect; ScanSnap Manager handles it with the iX500 and iX100 | A capture from an owner; the most likely next Wi-Fi model |
| iX1500 | `159F` | Fujitsu SCSI | a dialect of the same protocol (ScanSnack): magic `ssNR`, its own discovery reply, registration and pairing on the touch panel, JSON calls | A second dialect in the client; USB close to the iX500's |
| iX1600 | `1632` | Fujitsu SCSI | treated like the iX1500 by ScanSnap Manager | As the iX1500 |
| iX1400 | `1630` | Fujitsu SCSI | none | The iX500's USB path |
| S1500, S500/S510, fi-5110EOX | `11A2`, `10FE`/`1155`, `1096` | Fujitsu SCSI | none | The USB path; low priority |
| S300, S1300, S1300i, S1100 | `1156`, `11ED`, `128D` | a different protocol that needs PFU's firmware uploaded by the computer | none | A separate driver and firmware we cannot ship: out of scope |
| SV600 | `128E` | a camera with its own commands | none | Out of scope |
| iX2400, iX2500 | `05CA:03E3` (iX2400) | unknown | unknown | Out of scope for now |

ScanSnap Manager's Wi-Fi framework names the iX1300, iX1500 and iX1600 next to the iX500 and iX100, and
its interface version 0x0100 matches the iX1500 registration ScanSnack captured, so one family of protocols
covers them; the dialects differ enough that our client would not work unchanged.

## Out of scope

- Models the maintainer cannot test, unless someone who owns one contributes and tests the support (see
  "Other models").
- OCR, PDF building, naming and cloud upload: app concerns.
