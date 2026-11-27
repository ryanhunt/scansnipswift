# ScanSnap iX100 Wi-Fi protocol

Observed by scansnipswift on 2026-11-27 with an iX100 on firmware `0V00`, on a home Wi-Fi network (the
scanner joined the access point; its own access-point mode was not tried). Sources:

- probes and registrations sent from a Mac;
- two captures of the ScanSnap Home iOS app on an iPhone scanning blank sheets, recorded with `rvictl` and
  `tcpdump`: one with the default (automatic) settings, one with each colour mode, each image quality and
  A4 paper. The captures stay private; only the facts below were taken from them.

Read [PROTOCOL-iX500-WiFi.md](PROTOCOL-iX500-WiFi.md) first: the iX100 speaks the same `VENS` protocol (ports,
framing, discovery reply, password encoding, SCSI tunnel), and this file lists what was seen and what
differs. Everything here is from one scanner on one day.

## Discovery (UDP 52217)

- The iX100 answers the iX500's `VENS` probe (flag 0x0010) with the same 132-byte reply: interface version 6,
  device type 0x30, `ffffffff` at 12, scan port 53218 and control port 53219, name `iX100-<serial>` at 40,
  model `ScanSnap iX100` at 104. It ignores `ssNR`, `V2ss` and `SAV2` probes.
- With no computer or phone connected, the registered-host IP is `0.0.0.0` and the host ID is all `FF`
  bytes. The state word at 36 read `0x00800007` (the iX500 reports 1, 2 or 4; meaning unknown).
- The iOS app broadcasts four probes at once (`VENS`, `SAV2`, `ssNR`, `V2ss`) from UDP 55264, then sends
  heartbeats (`VENS`, sequence 1, flag 0x1000) to the scanner in bursts of three, about 0.5 s apart, every
  ~6 s. The scanner answers each with 12 bytes, `VENS 80 01 00 00 00 00 00 00`, as the iX500 does.
- Turning the scanner on (by opening its paper guide) broadcast the lid-opened notice (event 0x21) to UDP
  53220 three times.

## Control channel (TCP 53219)

**Send each command as soon as the 16-byte greeting arrives.** A registration sent about a second after the
greeting found the connection closed, with no answer; the app sends 2 ms after the greeting.

### Registration (0x11)

The app's registration is accepted (status 0) and carries:

| Body offset | App's value | Note |
|---|---|---|
| 0 | `00 06 1e 00` | interface version, scanner timeout, as on the iX500 |
| 4 | u32 **1** | reserve mode: 1 for a mobile client (a Mac with ScanSnap Home sends 0) |
| 8 | u32 1 | a password follows |
| 12 | phone IPv4 | |
| 16 | u32 55275 | notification port (ScanSnap Home on a Mac uses 55265) |
| 20 | encoded password | the factory password, encoded as on the iX500 |
| 68 | local date and time | |
| 76 | **8 zero bytes** | no host ID |
| 84 | i32 −39600 | time-zone bias (UTC+11) |
| 88–351 | zeros | the body is 352 bytes, the iX1500's length |

From a Mac, with the factory password:

| Reserve mode | Host ID | Body length | Status |
|---|---|---|---|
| 1 | zero | 352 | 0, accepted |
| 1 | zero | 96 | 0, accepted |
| 0 | zero | 352 | −6 |
| 0 | the Mac's (`en0` MAC shifted left 16 bits) | 96 | −6 |

So a mobile registration needs only the password: no pairing, no host ID and no real MAC (the header MAC was a
random locally administered one). The registration reply is 20 bytes with `00 06 00 00` at 12, as on the iX500.
`VENS.RegistrationStatus.notPaired` names −6.

### Other control commands

| Command | Body | Reply |
|---|---|---|
| 0x30 status | none | u32 3, then `02 00 80 64` (the last byte is probably the battery level, 100%) |
| 0x40 | 4100 bytes: `00 00 10 00`, opcode `0a 00 00 00`, … | 4100 bytes; with opcode 0x0A the ASCII version `02.02`. open-scansnap reads the same network-setup version over USB (`SETUP NET CMD`, opcode 0x0A), so 0x40 looks like network setup over Wi-Fi. Not explored further. |
| 0x12 release | none | a bare 16-byte frame, status 0 |

## Scan channel (TCP 53218)

Device information, each on its own connection, before scanning:

| CDB | Reply |
|---|---|
| `12 00 00 00 60 00` INQUIRY | `FUJITSU ` `ScanSnap iX100  `, revision `0V00` |
| `12 01 f0 00 90 00` VPD page 0xF0 | 144 bytes; holds 0x0258 (600) and 0x0032 (50) twice, probably the maximum and minimum resolutions |
| `e7 00 01 00 00 00 00 0c 00 00` | the serial number (not recorded here) |
| `e7 00 00 00 00 00 00 40 00 00` | firmware `0V00`, then `ff` padding |
| `d9 00 00 00 20 00` | three equal u32 page counters |
| `eb 00 01 00 00 00 00 04` | 4 bytes, `05 01 00 xx` (battery-save setting; the iX500 answers 0) |
| `e6 00 01 00 00 00 00 04` | 4 bytes, `00 00 00 00` (auto power-off) |
| `c2 … 20 00` hardware status | 32 bytes; see below |

The app then writes `e6 00 00 00 00 04 00 00` with `00 00 00 00` and `eb 00 00 00 00 04 00 00` with
`05 01 00 00` (4 bytes out each).

The scan itself, on one connection:

```
D8                    (CancelRead)
D4 00 00 00 LL 00     scan parameters: 128 bytes with automatic colour, else 80 (see below)
D5 00 00 00 08 08     StartJob, 8 zero bytes out, 8 zero bytes back
E0                    StartPaper
28 00 00 02 00 00 04 00 00 00 nn 00   read page nn, up to 0x40000 bytes: one whole image, then CHECK CONDITION
03 00 00 00 12 00     REQUEST SENSE: key 0, end of medium and incorrect length, information = residual
C2 …                  hardware status, polled about 100 times over 13 s (probably waiting for another sheet)
D6                    EndJob, on the same connection, status 0
```

For more pages in one job the app repeats `E0` and the read with the next page number (0, 1, …): the
index counts pages, since the iX100 has one side. In the one two-page job seen, the app sent `D8` before
`D6`.

No `E9` (SetPreReadMode), no image-information read, and `D6` was answered on the scan connection (the iX500
answers it only on a new one). The control-channel release (0x12) followed about 11 s later.

Hardware status (`C2`, 32 bytes): with a sheet inserted `00 00 80 00 00 01 20 00 …`, after it was fed
`00 00 00 80 00 01 20 00 …`. Byte 3 bit 7 is set once the sheet is gone, as on the iX500
(`VENS.hopperHasPaper`). Bytes 16–18 were `c0 80 64` both times (0x64 = 100, probably the battery level).

### Scan parameters (`D4`)

`VENS.iX100ParameterBlock` builds these; its tests compare against all eight blocks the app sent. The app's
default (automatic) settings:

```
  0  00 01 01 01 80 01 c1 c1 e0 c8 a0 80 80 00 00 81
 16  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 30
 32  00 10 00 00 00 00 05 82 0b 00 00 00 28 80 00 00
 48  a5 43 04 00 00 00 01 01 01 00 00 00 00 00 00 00
 64  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
 80  01 10 00 00 00 00 02 82 0b 00 00 00 28 80 00 00
 96  a5 43 04 00 00 00 01 01 01 00 00 00 00 00 00 00
112  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

32 bytes of parameters, then 48-byte window descriptors: two (colour and grey, the scanner picking one per
page) when the colour mode is automatic, else one. Changing one setting at a time in the app gave:

| Parameter byte | Automatic | Fixed |
|---|---|---|
| 2, 3, 5 | 1 (automatic page size) | 0 (A4) |
| 7 | 0xC1 (automatic colour) | 0x80 (colour, grey or black and white) |
| 10 | 0xA0 (automatic resolution) | 0x80 (150, 200 or 300 dpi) |
| 15 | 0x81 (automatic page size) | 0 (A4) |

Bytes 1, 4, 6, 8, 9, 11, 12 and 31 were `01`, `80`, `c1`, `e0`, `c8`, `80`, `80` and `30` in every block.

| Window byte | JPEG (colour, grey) | Black and white |
|---|---|---|
| 0 | window ID (0, or 1 for the second window) | 0 |
| 1 | 0x10 | 0x40 |
| 2–5 | u16 dpi x, u16 dpi y: 0 for automatic, else 150, 200 or 300 | 0 (automatic) |
| 6 | composition: 5 colour, 2 grey | 0 |
| 7, 8 | 0x82, quality 0x0B | 0x03, 0 |
| 10–17 | u32 width, u32 height in 1/1200 inch: `2880`/`a543` automatic, `26d0`/`36d0` A4 | same |
| 18, 22–24 | 4, then `01 01 01` | same |
| 25, 28 | 0, 0 | 1, 6 |

The iX100's A4 width (0x26D0) is not the iX500's (0x26C1); the height matches. The app offers no 600 dpi
("Excellent") for the iX100, and black and white was only captured with automatic resolution.

### The images

Each read returns the chunk header `00 00` (page number, chunk 0) and then one whole image:

| Settings | Image |
|---|---|
| automatic | grey JPEG, 1644 × 2315 at 200 dpi |
| colour | colour JPEG (3 components), 1664 × 2363 at 200 dpi |
| grey | grey JPEG, 200 dpi (two pages) |
| black and white | **TIFF**, little-endian, CCITT Group 4, 1 bit, white is zero, one strip, 3296 × 4616 at 400 dpi |
| Normal / Better / Best | grey JPEG at 150 / 200 / 300 dpi (2464 × 3475 at 300) |
| A4 | grey JPEG, 1648 × 2336 at 200 dpi: the full A4 area (8.24 × 11.68 in) |

So the iX100 crops the page on the scanner when the size is automatic, and with automatic colour it sent grey
for the blank sheets. The iX500, by contrast, always sends whole-area colour JPEGs. Whether pages need
rotating was not checked (the sheets were blank).

## Scanning from a Mac with this package

On 2026-11-27 a throwaway Mac tool that used only `ScanSnipProtocol` for the wire format scanned four blank
sheets from the iX100, one job each. It discovered the scanner, registered with `Registrant.mobile`, then sent
`D8`, `iX100ParameterBlock`, `D5`, polled `C2` until a sheet was in, then `E0`, one read, `D6`, and released.
Heartbeats went every 5 s.

| Settings | Image |
|---|---|
| automatic | grey JPEG, 1647 × 2316 at 200 dpi |
| colour | colour JPEG, 1641 × 2315 at 200 dpi |
| grey | grey JPEG, 1641 × 2319 at 200 dpi |
| black and white | Group 4 TIFF, 3296 × 4636 at 400 dpi |

Each matched what the iOS app got with the same setting. Each image came in one read with end-of-medium
sense. Lessons:

- **Register before any other control command.** A status request (0x30) sent before registering got the
  connection closed with no answer; after registering it answered.
- **An unfinished job keeps the scanner busy.** One scan polled `C2` only 3 s after the previous sheet and fed
  at once; the read then got no answer in 15 s. The tool released (0x12) but never sent `D6`, and from then on
  every registration, from any client MAC, got −4 (busy) until the scanner was turned off and on again.
  Always send `D6` before releasing, even after an error.
- **Feed only a loaded sheet.** The stall above came from feeding on byte 3 of `C2` (a sheet at the slot)
  before the scanner had loaded it; see "Sheets, blank pages and large pages" below.
- The status word (0x30) read 2 right after power-on and 3 after a scan.

## From an iPhone

On 2026-11-27 the demo app (`Examples/ScanSnipDemo`) ran the same `ScanSnipScanner` code on an iPhone 15 Pro
Max with iOS 27.2.1: it found the iX100 at its address 2.6 s after launch, registered as a mobile client,
scanned a page (a 61 KB grey JPEG at 200 dpi), ended the job and released the scanner. The app declares
`NSLocalNetworkUsageDescription` and needs no entitlement for a scanner at a known address. Broadcast
discovery and background scanning were not tried.

## Sheets, blank pages and large pages

Found while building `ScanSnipScanner` (2026-11-27, firmware 0V00), with the `scansnip` tool's `--trace`
and the iOS-app captures.

**Hardware status (`C2`) has two sheet bits.** Byte 3 bit 7 clears as soon as a sheet reaches the slot
(`00 00 00 00`); byte 2 bit 7 sets once the scanner has loaded it (`00 00 80 00`). In both captures the app
fed only on `00 00 80 00`, at once (within 0.1 s), and never on `00 00 00 00`. `VENS.iX100SheetReady` reads
byte 2. The client waits for it, then starts a job and feeds straight away, one job per sheet.

**Some blank sheets come back with no image.** With the app's settings, several sheets with nothing on them
came back as a read of only the chunk header (`00 00`) and end-of-medium sense, residual `0x3FFD5`, in
automatic and in fixed colour mode. Every sheet with print (even faint show-through) scanned, but so did one
nearly blank sheet from the iPhone demo (a white page with a faint edge shadow). So this is probably the
scanner's blank-page removal with a threshold, but that is not proven, nor which `D4` byte controls it.
`WiFiScanner` counts such sheets in `blankPagesSkipped` and yields no page.

**A page larger than one read (0x40000 bytes) comes in several.** The first read answers GOOD with a full
buffer; the last answers CHECK CONDITION with end of medium. Every read after the first starts with the
same chunk header `00 00` (the chunk number does not go up), then two unknown bytes (`13 8f` and `8e b8`
seen) and a copy of the JPEG's leading `APP0` and comment segments: 43 bytes in all, which are not image
data. Joined without them, a 425 KB colour page decoded cleanly; joined with them, it had a smeared band
where the reads met. `VENS.iX100ContinuationPrefixLength` gives the length to drop; the client checks the
copy before dropping it. Multi-read black-and-white (TIFF) pages have not been seen.

**Other observations.**
- A printed page came back upside down (rotated 180°), as iX500 pages do. Whether that depends on how the
  sheet is put in was not checked.
- The status reply's last byte went 0x64, 0x5F, 0x50, 0x4A over an evening of scanning on battery: the
  battery level in percent.
- An idle iX100 announces an all-`FF` registered-host ID; `Announcement.hasRegisteredHost` treats it as none.

## Open questions

1. `D4` combinations not captured: fixed colour with a fixed resolution, black and white at a fixed
   resolution, page sizes other than A4, the meaning of the constant bytes, and which one turns blank-page
   removal off (capture the app with "remove blank pages" off).
2. The two bytes in front of a continuation read's copied segments (`13 8f`, `8e b8`).
3. Whether the iX500 accepts a mobile registration (reserve mode 1) the same way.
4. What −6 means exactly, and what the iX100 returns to a paired host.
5. The discovery state word `0x00800007`, the `SAV2` probe, and status word 2 versus 3.
6. Control command 0x40 and its other opcodes.
7. The iX100's own access-point mode (the scanner as the network).
8. USB: the USB ID (`04C5:13F4`, from Scan) and INQUIRY over USB.
