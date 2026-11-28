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
| 0x30 status | none | u32 3 (2 right after power-on), then `02 00`, flags (`80`; `c0` with the battery at 6%, so 0x40 is probably "battery low") and the battery level in percent: `VENS.ControlStatus` |
| 0x40 | 4100 bytes: a big-endian u32 length 0x1000, then a 4096-byte block starting with the opcode as a little-endian u32 (`0a 00 00 00`), … | 4100 bytes; with opcode 0x0A the ASCII version `02.02`. open-scansnap reads the same network-setup version over USB (`SETUP NET CMD`, opcode 0x0A). ScanSnap Manager calls 0x40 EXEC WIFI TOOL CMD (see "What ScanSnap Manager's files say"). Not explored further. |
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
discovery and background scanning were not tried at first.

Later the same day, with the scanner forgotten, the app found it **by broadcast** in 0.3 s: a development
build with no `com.apple.developer.networking.multicast` entitlement sent the discovery probe to the subnet
broadcast address and received the scanner's (unicast) reply. On the next launch it found the scanner at the
remembered address in 0.1 s. Whether an App Store build behaves the same was not checked; Apple's DTS states
that sending broadcasts needs the multicast entitlement and is enforced for BSD sockets from iOS 16, so do not
rely on it. From the Mac, probing each address on the /24 one by one (the fallback where a broadcast is
refused, or answered by nobody) also found it.

**iPad.** The same app on an iPad Pro 12.9-inch (5th generation, iPadOS 27.2.1) found the scanner by broadcast
and scanned a page. Once its Wi-Fi dropped after about two minutes ("Network is down"); the client ended the
scan and released the scanner.

**Background (iOS 27.2.1).** An app that asks for background time with `beginBackgroundTask` gets about 29 s
(`backgroundTimeRemaining` reads "unlimited" until the app is fully in the background). In that time the scan
carries on: a sheet put in after leaving the app was detected, loaded, fed and read, and a page being read
when the app left completed. Stopping with 15 s left released the scanner cleanly (a cancel mid-read lost the
page, hence `stopAfterCurrentSheet()`). A suspended app sends no heartbeats and cannot end a job, so never let
one be suspended mid-job.

**Battery.** Over an evening of scanning on battery the level fell from 100% to 6%. At 6% the scanner closed
one session about 35 s after registering and stopped answering another after about 57 s; charged, it behaved
normally. Check `ControlStatus.batteryPercent` before blaming the protocol.

**Counters and identity.** INQUIRY answered `FUJITSU`, `ScanSnap iX100`, revision `0V00`; the three page
counters (`D9`) were equal and rose with every sheet.

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

## Over USB

Checked on 2026-11-29 from a Mac (macOS 27.2.1), firmware 0V00, with a throwaway tool on Apple's IOUSBHost
framework (no libusb):

- **Device:** vendor `04C5`, product `13F4` (as Scan's tests had it), USB 2.0 high speed. One configuration
  with one interface, class/subclass/protocol `FF/FF/FF`, two endpoints: bulk OUT `0x02` and bulk IN `0x81`,
  512-byte packets. No macOS driver claims the interface, so a normal process can open it.
- **Commands** use the 31-byte block known from the iX500 (byte 0 `0x43`, the CDB at `0x13`) on bulk OUT,
  then the data on bulk IN, then a 13-byte status packet: `53` ("S") at byte 0, the SCSI status at byte 9.
- **INQUIRY** answered `FUJITSU`, `ScanSnap iX100`, `0V00`, as over Wi-Fi.
- **Hardware status (`C2`)** answered `00 00 00 80 80 01 20 00` with no sheet in: byte 3 as over Wi-Fi, but
  byte 4 `80` where Wi-Fi showed `00` (meaning unknown; perhaps the USB connection or power).
- **The Wi-Fi vendor commands are refused** over USB: `D9` (counters) and `E7` (firmware) gave CHECK
  CONDITION with sense 5/20/00 (invalid command). Scanning over USB therefore needs Fujitsu's SCSI command
  set, not the `VENS` sequence.
- **Wi-Fi stays on** while USB is connected: the scanner still answered discovery.
- Through a Thunderbolt dock the scanner did not enumerate at all; plugged straight into the Mac (micro-USB to
  USB-C) it did.

### Scanning over USB, and ScanSnap Cloud

A first USB scan (2026-11-29) ran the iX500's USB sequence (facts from Scan's driver). The iX100 accepted TEST
UNIT READY, INQUIRY, the VPD page, the feeder select (`F1 00`), four MODE SELECT pages, SET WINDOW, the gamma
table and lamp on (`F1 05`), but refused every command that moves paper with **sense 3/80/33**: the pre-read
setup (`1D`, "SET PRE READMODE"), OBJECT POSITION feed (`31 01`) and halt (`31 04`), with or without a loaded
sheet. The scanner was in **ScanSnap Cloud mode** (its Scan button lit purple, and pressing it sent the sheet to
the cloud). Over USB the hardware status byte 4 read `80` with the lamp off and `00` with it on.

**With ScanSnap Cloud off the scan works** (2026-11-29, the Scan button lit blue, ScanSnap Home quit): the same
sequence fed the sheet and read it at 150 dpi in colour. After the sheet was loaded (byte 2 bit 7, as over Wi-Fi),
in order: `F1 00`, `1D` pre-read (32 bytes), MODE SELECT pages `3C` (automatic length), `38` (multifeed off),
`39`, `3A` (buffering off), SET WINDOW (one 64-byte descriptor: 150 dpi, colour, 8.5 × 14 in), SEND gamma, `F1
05` lamp on, OBJECT POSITION `31 01` (feed), SCAN `1B`, then READ:

- The pixel size read (`28 00 80 … 20`) gave 1274 × 2100, the window's size.
- Image reads of 0x3F738 bytes (whole lines of RGB) came back full until the last, which ended with CHECK
  CONDITION, sense 0/00/00 with end of medium and incorrect length set, and the information field the number
  of bytes missing: 26 reads, 1767 lines, so the page length was found by the scanner (299 mm for an A4 sheet).
- The samples are inverted (255 is black). Lines come in the order the sheet is fed: a later sheet marked
  "top" and fed top edge first came out upright. (The first sheet came out upside down; it must have gone in
  bottom first.)
- A second OBJECT POSITION answered 3/80/03 (no paper): the end of the job.

Byte 4 of the hardware status read `80` with no sheet and `00` once the sheet was being loaded.

**ScanSnap Cloud mode is a setting kept on the scanner** (2026-11-29). ScanSnap Home switches it in its Scan
window, and only with the scanner on USB; turning the scanner off and on does not change it. With it on, the
Scan button lights purple and every command that moves paper answers 3/80/33. The light turns blue while a
computer holds the scanner (ScanSnap Home open, or a `SETUP NET START` session over USB until `SETUP NET END`),
but that alone does not lift the block: inside such a session the first setup command after loading a sheet
still answered 3/80/33. With the scanner's **Wi-Fi switch off** it lit blue and scanned over USB normally, with
this package's `USBScanner` (`scansnip usb scan`): 1274 × 605 at 150 dpi for a short card, the job ended
cleanly. So for USB scanning, either turn Cloud mode off in ScanSnap Home or switch Wi-Fi off on the scanner.

The setup session over USB: SEND DIAGNOSTIC (`1D 00 00 00 10 00`) with the 16 characters `SETUP NET START ` or
`SETUP NET END   `, then RECEIVE DIAGNOSTIC RESULTS (`1C 00 00 00 40 00`); both answered GOOD, and the 64-byte
result started `00` (success).

ScanSnap Home's background helper (`SshResident`, started at login) holds the USB interface while it runs,
so no other process can open it (`IOUSBHostInterface` cannot be created). Its Wi-Fi tool stops the helper
before using USB; stopping it ourselves while it held the scanner left the scanner stuck (below).

**Stuck after an aborted run.** A process that failed in the middle and sent its halt commands with long
timeouts left the scanner accepting no transfers (every write timed out, `0xe00002d6`) though it stayed on
the bus; clearing the endpoint halt did not help, and closing and reopening the feed guide (which turns it off
and on) did. The first command after the scanner wakes can also fail once; a retry works.

Names and messages in ScanSnap Manager 7.2.70's files (read 2026-11-29, for interoperability; no code read)
point the same way: while the ScanSnap Cloud link is on, it will not scan over USB or Wi-Fi until that link is
turned off, it checks whether the device is "cloud enabled" or "cloud occupied" from the hardware status, and it
warns that a scanner can be taken over by a mobile device. So 3/80/33 most likely means "held by cloud or
mobile use"; no table in the files maps sense codes to messages, so this is inferred, not proven. The same
files name the registration results in an order that fits our codes (−2 password option, −3 wrong password,
−4 already occupied, −6 host ID not registered, −7 wrong host ID), making −5 most likely "unsupported interface
version"; name the status reply's fields (Wi-Fi status, battery status, battery level, Wi-Fi modes, signal
strength); and log the discovery reply's fields in an order suggesting offset 36 holds four bytes: set mode,
Wi-Fi mode, cloud status and device status.

## What ScanSnap Manager's files say

Facts read on 2026-11-29 from ScanSnap Manager 7.2.70 for Mac and its Wi-Fi setup tool, for interoperability:
its help pages, string tables and property lists, and the names and type layouts left readable in its programs.
No code was disassembled and the apps were not run. Layouts below are what those names say; anything not
also seen on the wire is marked as such.

**Consumables.** The scan-channel command `D9` is GET CONSUMABLES INFO: three u32 and 20 reserved bytes, which
matches our 32-byte read. The iX500 has one consumable, the roller set (pick and brake roller), with a
suggested replacement every 200,000 sheets (`ScanSnapModel.rollerSetReplacementSheets`); the window shows the
total page count and the roller set count, each with its own reset. Models with a separate pad count a third
value. The iX100 has no consumables (the window is not shown for it), which fits its three equal counters.
A RESET CONSUMABLES INFO command takes one byte, probably which counter; its opcode is not in the files. Over
USB the iX500 reads and clears the counts with SEND DIAGNOSTIC (`READ COUNT`, `READ COUNT CLR X`).

**Capabilities** (help pages):

| | iX500 | iX100 |
|---|---|---|
| Sides | duplex (default) | one side; "continue scanning" on by default |
| Image quality, colour/grey | Normal 150, Better 200, Best 300, Excellent 600 dpi | same |
| Image quality, black and white | 300, 400, 600, 1200 dpi | same |
| Custom paper size | 50.8–216 × 50.8–360 mm | 25.4–216 × 25.4–360 mm |
| Long pages | up to 863 mm: hold Scan 3 s or more, until it flashes | up to 863 mm |
| Multifeed detection | ultrasonic | none |
| Blank-page removal | on by default | on by default |

Automatic quality picks Better for pages longer than 148 mm and Best for shorter ones; Excellent turns long-page
scanning off. Whether the black-and-white resolutions come from the scanner or from the computer is not known.

**Errors.** Manager distinguishes paper jam, cover open, no paper, double feed, paper protection, lamp,
battery not installed, battery temperature, and the generic invalid-command and transfer errors. Its scanner
classes check sense key 3 (with qualifiers 01, 02, 07, 13), key 4, key 5 (codes 20, 24, 26, 2C) and key B. No
table pairs a sense code with a message, so the library keeps its own mapping (`SCSISense`). The iX100 has its
own wording for a jam: a jam or a page longer than the maximum.

**Notices.** The 48-byte notice has the event at 8, two sensor bytes at 12, two operation-panel bytes at 14
and the sequence number at 16 (our counter). Event names include a scan-button press, a long press (most
likely the 3-second press for long pages) and a warning before battery power-off; their codes are not in the
files beyond those we saw.

**Power.** Auto power-off can be Never, 1, 3, 5, 10 or 15 minutes, or 1, 2, 4 or 8 hours. Defaults: the iX500
turns off after 4 hours; the iX100 after 4 hours on USB power and 5 minutes on battery. The timer restarts on
loading, scanning, switching users or waking the computer. GET/SET POWER INFO (`E6`) and the battery save
mode (`EB`) both carry 4 bytes with no field names. A guess not yet checked: in `EB`'s `05 01 00 xx`, `05` is
the 5-minute battery default and `01` means on.

**Wi-Fi setup.** Control command 0x40 is EXEC WIFI TOOL CMD. Manager's block is 4096 bytes: a 16-byte header
of four u32 (its names: opcode, offset and size; the fourth is unnamed) and 4080 bytes of data. On the wire the
block follows a big-endian u32 length (0x1000), 4100 bytes in all, with the opcode first, little-endian
(inferred from the bytes we sent); opcode 0x0A asks for the functional version. Field sizes in the type names:
SSID 33 bytes, security 7, cipher 5, key 193, and IPv4 settings as a flag and three 16-character strings, which
suggests text values. The host table has room for 31 computers (from a type name; medium confidence). Over USB the same commands go through SEND DIAGNOSTIC (`SETUP NET START`, `SETUP NET CMD`, `SETUP NET
END`), next to the host-table ones (`REG HOSTID DATA`, `CLR HOSTID ADATA`, `GET HOSTID LEN`, `GET HOSTID
DATA`). The tool's functions include listing access points, WPS (push button and PIN), Wi-Fi and IP settings,
and the iX100's own access point. The iX100 has two modes, access-point connect (joins a network) and direct
connect (its own network with a DHCP server and WPS), plus an automatic mode that falls back to direct when no
access point answers; 802.11b/g/n. Tool timeouts: WPS 185 s, network 30 s, search 5 s.

**Other.**
- Wi-Fi client defaults: largest read 0x300000 bytes (we read 0x40000), 0x20000 when front and back are
  interleaved; ports 52217 and 55264.
- There are two registration layouts, the one we send and a newer one that also carries the app and the
  computer's name. That one is probably why the iOS app sends 352 bytes.
- Wi-Fi status reply fields, in order: error, battery status, battery level, the scanner's configured and
  current Wi-Fi mode, signal strength (four levels in the UI). So the status word we read as 3 may be the
  signal strength; not yet checked.
- READ has variants for the pixel size, the paper size, multifeed and the carrier sheet. START JOB has a
  "clear counter" flag.

## Open questions

0. The USB command ScanSnap Home sends to switch Cloud mode off (a USB capture of its Scan window would show
   it), and whether a client can see the mode before it tries to feed: the discovery state read `00800002`
   in Cloud mode.
1. `D4` combinations not captured: fixed colour with a fixed resolution, black and white at a fixed
   resolution, page sizes other than A4, the meaning of the constant bytes, and which one turns blank-page
   removal off (capture the app with "remove blank pages" off).
2. The two bytes in front of a continuation read's copied segments (`13 8f`, `8e b8`).
3. Whether the iX500 accepts a mobile registration (reserve mode 1) the same way.
4. What −6 means exactly, and what the iX100 returns to a paired host.
5. The discovery state word `0x00800007`, the `SAV2` probe, and status word 2 versus 3.
6. Control command 0x40's other opcodes, and the opcode of RESET CONSUMABLES INFO.
7. The iX100's own access-point mode (the scanner as the network).
8. USB: the scan sequence with Fujitsu's SCSI set, and what byte 4 of the hardware status (`80` on USB,
   `00` over Wi-Fi) means.
9. Whether the status word (3, or 2 after power-on) is the Wi-Fi signal strength, and what the iX500's
   `D9` counters hold after a roller change.
10. Which models send the `SAV2` and `V2ss` search packets, and which dialect the iX1300 speaks over Wi-Fi.
11. Whether `REG HOSTID DATA` without `CLR HOSTID ADATA` adds a computer to the host table instead of
    replacing them all.
