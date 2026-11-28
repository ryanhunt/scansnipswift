// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanSnip",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // Wire formats only, no I/O: the iX500 Wi-Fi ("VENS") protocol, SCSI sense data, the model table.
        .library(name: "ScanSnipProtocol", targets: ["ScanSnipProtocol"]),
        // Talks to a scanner over Wi-Fi with Network.framework: discovery and scan sessions.
        .library(name: "ScanSnipScanner", targets: ["ScanSnipScanner"]),
        // Talks to a scanner over USB: IOUSBHost on macOS. (Builds on iOS without the IOUSBHost channel.)
        .library(name: "ScanSnipUSB", targets: ["ScanSnipUSB"]),
    ],
    targets: [
        .target(name: "ScanSnipProtocol"),
        .testTarget(name: "ScanSnipProtocolTests", dependencies: ["ScanSnipProtocol"]),
        .target(name: "ScanSnipScanner", dependencies: ["ScanSnipProtocol"]),
        .testTarget(name: "ScanSnipScannerTests", dependencies: ["ScanSnipScanner"]),
        .target(name: "ScanSnipUSB", dependencies: ["ScanSnipProtocol", "ScanSnipScanner"]),
        .testTarget(name: "ScanSnipUSBTests", dependencies: ["ScanSnipUSB"]),
    ]
)
