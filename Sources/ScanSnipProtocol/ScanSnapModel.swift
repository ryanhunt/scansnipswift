/// A ScanSnap model this package knows about, and how it can be reached.
///
/// Only models the maintainers can test are listed. USB product IDs come from holgerkrupp/Scan
/// (`FujitsuScanSnapModelProfile.swift`, `FujitsuScanSnapDriverTests.swift`); check them against
/// `system_profiler SPUSBHostDataType` on real hardware before relying on them.
public struct ScanSnapModel: Sendable, Hashable, CustomStringConvertible {
    /// How a model talks over Wi-Fi.
    public enum WiFiProtocol: Sendable, Hashable {
        /// The iX500's protocol: TCP/UDP with the magic `VENS`. See `VENS`. The iX100 speaks it too, with
        /// its own scan settings and sequence (docs/PROTOCOL-iX100-WiFi.md).
        case vens
        /// The model has Wi-Fi but nobody has documented its protocol yet.
        case undocumented
    }

    /// Fujitsu/PFU's USB vendor ID, shared by every ScanSnap.
    public static let usbVendorID: UInt16 = 0x04C5

    /// Marketing name, for example "iX500".
    public let name: String
    /// USB product IDs (the vendor is always `usbVendorID`).
    public let usbProductIDs: [UInt16]
    /// Whether the scanner can read both sides of a sheet in one pass.
    public let duplex: Bool
    /// Whether it has a multi-sheet feeder (the iX100 takes one sheet at a time).
    public let sheetFeeder: Bool
    /// Its Wi-Fi protocol, or nil if it has no Wi-Fi.
    public let wiFi: WiFiProtocol?
    /// Resolutions the scanner accepts, in dots per inch.
    public let resolutions: [Int]

    public var description: String { "ScanSnap \(name)" }

    /// ScanSnap iX500 (2012): duplex sheet feeder, USB and Wi-Fi. The iX500 EE shares it under another ID.
    public static let iX500 = ScanSnapModel(
        name: "iX500",
        usbProductIDs: [0x132B, 0x13F3],
        duplex: true,
        sheetFeeder: true,
        wiFi: .vens,
        resolutions: [150, 200, 300, 600]
    )

    /// ScanSnap iX100 (2014): battery-powered, one sheet at a time, one side, USB and Wi-Fi.
    /// Over Wi-Fi it answers `VENS` discovery and accepts mobile registrations (checked on firmware 0V00,
    /// 2026-11-27). Its USB ID was confirmed on hardware (2026-11-29); its resolutions are not yet.
    public static let iX100 = ScanSnapModel(
        name: "iX100",
        usbProductIDs: [0x13F4],
        duplex: false,
        sheetFeeder: false,
        wiFi: .vens,
        resolutions: [150, 200, 300, 600]
    )

    public static let all: [ScanSnapModel] = [.iX500, .iX100]

    /// The model behind a USB vendor and product ID, if it is one this package knows.
    public static func matching(usbVendorID vendor: UInt16, productID: UInt16) -> ScanSnapModel? {
        guard vendor == usbVendorID else { return nil }
        return all.first { $0.usbProductIDs.contains(productID) }
    }

    /// The model behind a Wi-Fi discovery reply's model field, for example `"ScanSnap iX500  "`.
    public static func matching(announcedModel: String) -> ScanSnapModel? {
        let words = announcedModel.split(separator: " ")
        guard words.count >= 2, words[0] == "ScanSnap" else { return nil }
        return all.first { $0.name == words[1] }
    }
}
