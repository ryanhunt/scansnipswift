# Capturing a ScanSnap's USB traffic

To learn what an app such as ScanSnap Home sends a scanner over USB, record the traffic, then turn it into a
list of SCSI commands with `scansnip decode-usb`. This is how to find commands nobody has documented, such as
the one ScanSnap Home sends to switch an iX100 out of ScanSnap Cloud mode, or a new model's scan sequence.

**Captures hold private data.** They contain the scanner's serial number (in device ID and VPD replies), any
passwords and Wi-Fi keys sent during setup, and the images of whatever was scanned. Keep them in `captures/`
(ignored by git), scan a blank sheet with a pen mark rather than a document, and never commit or attach a
capture. Commit the facts you learn from it.

## Where to capture

| Route | Status |
|---|---|
| **Windows with USBPcap** (Wireshark's installer includes it) | The usual way. Run ScanSnap Home for Windows and capture on the USBPcap interface of the root hub the scanner is on. |
| **Windows 11 on ARM in a VM** on an Apple silicon Mac, with the scanner passed through to the VM | ScanSnap Home for Windows supports the iX100 on ARM-based Windows 11 since May 2026 (PFU's announcement). Whether USBPcap installs on ARM64 Windows is not yet checked. |
| **Linux with usbmon** (`sudo modprobe usbmon`, capture on `usbmonN`) | Works for any app that runs on Linux; ScanSnap Home does not. |
| **macOS** | Not available: the `XHC` capture interfaces need System Integrity Protection turned off on Apple silicon and are reported broken on recent macOS. Do not turn SIP off for this. |

## Steps (Windows)

1. Install Wireshark with USBPcap, and ScanSnap Home for Windows. Plug the scanner in and let Home find it,
   then quit Home.
2. Start Wireshark as administrator and capture on the USBPcap interface for the scanner's hub (with USBPcap's
   "capture from all devices" on, or only the scanner's device).
3. Do the one thing you want to learn, and nothing else: for example open Home, open the Scan window and switch
   Cloud mode off. Note the time.
4. Stop and save as `captures/<what>.pcapng`.
5. Decode on the Mac:

```bash
swift build --package-path Tools/scansnip
Tools/scansnip/.build/debug/scansnip decode-usb captures/<what>.pcapng --bytes 32
```

Each line is one command: its name, CDB, the data sent (SEND DIAGNOSTIC's 16-character command name, such as
`SETUP NET START `, is shown as text), the data read back and the SCSI status. `ScanSnipCapture` does the
decoding (classic pcap and pcapng; USBPcap and Linux usbmon link types).

## What to capture next

- **iX100, Cloud mode off and on** from ScanSnap Home's Scan window (the command that switches it).
- **iX100, Wi-Fi setup** from ScanSnap Home's Wi-Fi tool: viewing the settings, then re-applying the same
  network (see the staged plan in docs/ROADMAP.md).
- **iX500, one scan** from ScanSnap Home, to compare with the sequence this package sends.
