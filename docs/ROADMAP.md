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
2. **Wi-Fi client for the iX500 and iX100** (new target `ScanSnipScanner`, Network.framework), tried first
   on the iX100:
   - UDP discovery (broadcast plus known addresses; on iOS, broadcast needs the multicast entitlement) and
     a heartbeat at least every 10 s while a session is open;
   - a stable, locally administered client MAC per host (the scanner keys sessions to it);
   - the host ID from the real en1/en0 MAC through SystemConfiguration (macOS);
   - registration on the control channel, mobile by default, sending each command as soon as the greeting
     arrives;
   - per-model scan sequences: the iX500's, and the iX100's (`D8`, a 128-byte `D4`, `D5`, `E0`, one read per
     page, `D6` on the same connection);
   - an actor session for the scan channel that runs one command at a time, reads frames with
     `VENS.frameLength`, and always ends the job (`D6`: on a new connection on the iX500, the same one on the
     iX100) and releases (control `0x12`), including on errors and cancellation. A job left without `D6`
     keeps the iX100 busy until it is power-cycled;
   - before waiting for the next sheet, wait for the feeder to read empty (`hopperHasPaper` false);
   - a page stream that yields JPEGs and starts a new job every 120 sheets;
   - a simulated scanner for tests, enforcing the one-client rule and the release order;
   - a `scansnip` CLI (`discover`, `status`, `scan`) for checking against hardware.
   References: Scan's `VENSNetwork.swift` and `FujitsuScanSnapWiFiDriver.swift` (MIT; adapt, removing
   UserDefaults and app types); open-scansnap's `discovery.py` and `scanner.py` (MIT) for discovery, the host
   ID and following a scanner to a new address. Its Wi-Fi transport is in its GPL SANE fork: facts only.
3. **iOS spike [HW]:** run the client from an iPhone. The protocol side is answered (a mobile registration
   needs only the password, any stable MAC works); what is left is the local-network permission, broadcast
   discovery (the multicast entitlement, or a known address), and running in the foreground only.
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
