# ScanSnap iX100 Wi-Fi protocol

Observed by scansnipswift on 2026-11-27 with an iX100 on firmware `0V00`, on a home Wi-Fi network (the
scanner joined the access point; its own access-point mode was not tried). Sources:

- probes and registrations sent from a Mac;
- one capture of the ScanSnap Home iOS app on an iPhone scanning a blank sheet with its default
  settings, recorded with `rvictl` and `tcpdump`. The capture stays private; only the facts below were
  taken from it.

Read [PROTOCOL-iX500-WiFi.md](PROTOCOL-iX500-WiFi.md) first: the iX100 speaks the same `VENS` protocol (ports,
framing, discovery reply, password encoding, SCSI tunnel), and this file lists what was seen and what
differs. Everything here is from one scanner and one session.

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
D4 00 00 00 80 00     scan parameters, 128 bytes out (the iX500 takes 80)
D5 00 00 00 08 08     StartJob, 8 zero bytes out, 8 zero bytes back
E0                    StartPaper
28 00 00 02 00 00 04 00 00 00 00 00   read image 0, up to 0x40000 bytes: one whole JPEG, then CHECK CONDITION
03 00 00 00 12 00     REQUEST SENSE: key 0, end of medium and incorrect length, information = residual
C2 …                  hardware status, polled about 100 times over 13 s (probably waiting for another sheet)
D6                    EndJob, on the same connection, status 0
```

No `E9` (SetPreReadMode), no image-information read, and `D6` was answered on the scan connection (the iX500
answers it only on a new one). The control-channel release (0x12) followed about 11 s later.

Hardware status (`C2`, 32 bytes): with a sheet inserted `00 00 80 00 00 01 20 00 …`, after it was fed
`00 00 00 80 00 01 20 00 …`. Byte 3 bit 7 is set once the sheet is gone, as on the iX500
(`VENS.hopperHasPaper`). Bytes 16–18 were `c0 80 64` both times (0x64 = 100, probably the battery level).

### Scan parameters (`D4`, 128 bytes)

The app's default (automatic) settings:

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

32 bytes of parameters, then two 48-byte window descriptors (window 0 at 32 and window 1 at 80, though the
iX100 is single-sided). Read against the iX500's descriptor (`00 10 | dpi x | dpi y | 05 81 | quality | 00 |
width | height | 04`): resolution 0 (automatic), `05 82` and `02 82` where the iX500 has `05 81`, quality
0x0b, width 0x2880 (8.64 in) and height 0xA543 (35.3 in) in 1/1200 inch, then `04 00 00 00 01 01 01`. Other
settings have not been captured yet.

### The image

One read returned the chunk header `00 00` (image index 0, chunk 0) and then a complete baseline JPEG: **one
component (grey), 1644 × 2315 pixels at 200 dpi**, so about 8.2 × 11.6 in. With automatic settings the iX100
picks the resolution and colour mode and crops the page itself, unlike the iX500, which always sends whole-area
colour JPEGs. Whether the page needs rotating was not checked (the sheet was blank).

## Open questions

1. Other `D4` settings: fixed resolutions, colour, grey and black-and-white, and what each byte means.
2. Whether the iX500 accepts a mobile registration (reserve mode 1) the same way.
3. What −6 means exactly, and what the iX100 returns to a paired host.
4. The discovery state word `0x00800007`, and the `SAV2` probe.
5. Control command 0x40 and its other opcodes.
6. The iX100's own access-point mode (the scanner as the network).
7. USB: the USB ID (`04C5:13F4`, from Scan) and INQUIRY over USB.
