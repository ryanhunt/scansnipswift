// swift-tools-version: 6.0
// A command-line tool for checking ScanSnipScanner against a real scanner. Kept out of the main package so
// that package stays library-only and builds for iOS.
import PackageDescription

let package = Package(
    name: "scansnip",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "scansnip",
            dependencies: [
                .product(name: "ScanSnipProtocol", package: "scansnipswift"),
                .product(name: "ScanSnipScanner", package: "scansnipswift"),
                .product(name: "ScanSnipUSB", package: "scansnipswift"),
            ]
        ),
    ]
)
