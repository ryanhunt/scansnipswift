# Roadmap

Scope: the ScanSnap **iX500** and **iX100**, the models the maintainer can test. Apps own the UI, storage,
OCR and PDF assembly; this package supplies what talks to the scanner and what turns its output into pages.

**[HW]** marks work that needs a real scanner.

## Done

- **iX500 Wi-Fi protocol** (`ScanSnipProtocol`): frames, discovery and heartbeat probes, the discovery
  reply, notices, password encoding, registration body and status, the SCSI tunnel, scan commands, window and
  parameter blocks with page sizes, image chunk headers, the hopper bit. Adapted from holgerkrupp/Scan
  (`VENSProtocol.swift`, 413a7e5) and checked against ScanSnack's `docs/protocol-ix500.md` (cf3464f).
- **SCSI sense** parsing and paper problems.
- **Model table** with USB IDs for the iX500, iX500 EE and iX100.
- CI: `swift test` on macOS and an iOS Simulator build.

## Next

1. **Hardware check of what exists [HW].** On the iX500: capture a discovery reply and a registration
   (redact serial, MAC, host ID and IP) and compare them with the parsers. On both scanners: confirm the USB
   product IDs with `system_profiler SPUSBHostDataType`. Record results in
   `docs/PROTOCOL-iX500-WiFi.md` ("Notes from scansnipswift").
2. **Wi-Fi client for the iX500** (new target `ScanSnipScanner`, Network.framework):
   - UDP discovery (broadcast plus known addresses; on iOS, broadcast needs the multicast entitlement) and
     the heartbeat;
   - registration on the control channel;
   - an actor session for the scan channel that runs one command at a time, reads frames with
     `VENS.frameLength`, and always releases (`D6` on a new connection), including on cancellation;
   - a page stream that yields JPEGs and starts a new job every 120 sheets;
   - a simulated scanner for tests, enforcing the one-client rule and the release order;
   - a `scansnip` CLI (`discover`, `status`, `scan`) for checking against hardware.
   Reference: Scan's `VENSNetwork.swift` and `FujitsuScanSnapWiFiDriver.swift` (MIT; adapt, removing
   UserDefaults and app types).
3. **iOS spike [HW]:** can an iPhone or iPad drive the iX500 over Wi-Fi? Open questions: the client MAC
   (iOS hides the real one, and the scan channel checks it), the local-network permission, and the multicast
   entitlement for broadcast discovery.
4. **USB transport on macOS** (IOUSBHost, no libusb) **[HW]**: the 31-byte command wrapper (byte 0 `0x43`,
   CDB at 0x13), 13-byte status, REQUEST SENSE on a non-zero status, and the iX500 command sequence (SET
   WINDOW, gamma and JPEG tables, OBJECT POSITION, START SCAN, READ per side). Facts from Scan's
   `FujitsuSCSIOverUSB/` and SANE's documentation; **write the code fresh**, since parts of Scan's USB layer
   are GPL-derived. Hardware JPEG gives one stream per side on the iX500.
5. **iX100 over USB [HW]:** start from the iX500 command set without duplex and the back window; confirm
   INQUIRY, the VPD page and resolutions on hardware.
6. **Scan button:** UDP notices over Wi-Fi (`VENS.Notice`), hardware-status polling over USB (byte 4, mask
   0x21 on the iX500, per Scan).

## Later

- **Page finishing** in a separate target: rotate the iX500's Wi-Fi pages by 180°, drop backs for
  single-sided output, blank-page detection, grey and black-and-white conversion, deskew and crop. These are
  host-side on the iX500.
- **iX100 over Wi-Fi:** needs captures of ScanSnap Home talking to it (kept private; they contain documents
  and identifiers).
- **iPadOS USB** via DriverKit.
- **eSCL/AirScan bridge**, as ScanSnack does (ADR 0001 there), so other apps can scan through this package.

## Out of scope

- Models the maintainer cannot test, unless someone who owns one contributes and tests the support.
- OCR, PDF building, naming and cloud upload: app concerns.
