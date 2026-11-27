// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanSnip",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // Wire formats only, no I/O: the iX500 Wi-Fi ("VENS") protocol, SCSI sense data, the model table.
        .library(name: "ScanSnipProtocol", targets: ["ScanSnipProtocol"]),
    ],
    targets: [
        .target(name: "ScanSnipProtocol"),
        .testTarget(name: "ScanSnipProtocolTests", dependencies: ["ScanSnipProtocol"]),
    ]
)
