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
    ],
    targets: [
        .target(name: "ScanSnipProtocol"),
        .testTarget(name: "ScanSnipProtocolTests", dependencies: ["ScanSnipProtocol"]),
        .target(name: "ScanSnipScanner", dependencies: ["ScanSnipProtocol"]),
        .testTarget(name: "ScanSnipScannerTests", dependencies: ["ScanSnipScanner"]),
    ]
)
