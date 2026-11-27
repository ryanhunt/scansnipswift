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
   connection) once it is back on the desk; broadcast discovery (BSD sockets; on iOS the multicast
   entitlement); following a scanner to a new address; registering as a paired host (`VENS.hostID`) for
   Macs paired by ScanSnap Home; whether a `D4` byte controls the empty blank-sheet reads (capture the app
   with blank-page removal off); a `status` command in `scansnip`.
3. **iOS, the rest:** finding the scanner without typing its address (the iX100 advertises no Bonjour
   service, so broadcast discovery with the multicast entitlement, or remembering the last address);
   scanning while the app is in the background (not tried); an iPad run; CI building the demo app.
4. **USB transport on macOS** (IOUSBHost, no libusb) **[HW]**: the 31-byte command wrapper (byte 0 `0x43`,
   CDB at 0x13), 13-byte status, REQUEST SENSE on a non-zero status, and the iX500 command sequence (SET
   WINDOW, gamma and JPEG tables, OBJECT POSITION, START SCAN, READ per side). Facts from Scan's
   `FujitsuSCSIOverUSB/` and SANE's documentation; **write the code fresh**, since parts of Scan's USB layer
   are GPL-derived. Hardware JPEG gives one stream per side on the iX500.
5. **iX100 over USB [HW]:** start from the iX500 command set without duplex and the back window; confirm
   INQUIRY, the VPD page and resolutions on hardware.
6. **Pairing and Wi-Fi setup over USB [HW]:** SEND DIAGNOSTIC with 16-byte ASCII commands (`CLR HOSTID
   ADATA`, `REG HOSTID DATA `, `SETUP NET …`), per open-scansnap's notes. Pairing removes every other
   computer, so the API must say so. Lets an app pair a Mac without ScanSnap Home.
7. **Scan button:** UDP notices over Wi-Fi (`VENS.Notice`), hardware-status polling over USB (byte 4, mask
   0x21 on the iX500, per Scan).

## Later

- **Page finishing** in a separate target: rotate the iX500's Wi-Fi pages by 180°, drop backs for
  single-sided output, blank-page detection, grey and black-and-white conversion, deskew and crop. These are
  host-side on the iX500.
- **iPadOS USB** via DriverKit.
- **eSCL/AirScan bridge**, as ScanSnack does (ADR 0001 there), so other apps can scan through this package.

## Out of scope

- Models the maintainer cannot test, unless someone who owns one contributes and tests the support.
- OCR, PDF building, naming and cloud upload: app concerns.
