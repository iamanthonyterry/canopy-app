// swift-tools-version: 6.0
import PackageDescription

// Shared code for the Church Landing Page apps (Canopy and Transcriber).
// No third-party dependencies, so neither app inherits the other's.
let package = Package(
    name: "ChurchLandingPageKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChurchKitCore", targets: ["ChurchKitCore"]),
        .library(name: "ChurchKitAuth", targets: ["ChurchKitAuth"]),
    ],
    targets: [
        .target(name: "ChurchKitCore"),
        .target(name: "ChurchKitAuth"),
        .testTarget(name: "ChurchKitCoreTests", dependencies: ["ChurchKitCore"]),
        .testTarget(name: "ChurchKitAuthTests", dependencies: ["ChurchKitAuth"]),
    ]
)
