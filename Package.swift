// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.12.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
        // Shared with Canopy. A local checkout until the kit is published.
        .package(path: "../church-landing-page-kit"),
    ],
    targets: [
        .executableTarget(
            name: "Transcriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "ChurchKitCore", package: "church-landing-page-kit"),
                .product(name: "ChurchKitAuth", package: "church-landing-page-kit"),
            ],
            path: "Sources/Transcriber",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The .app bundle keeps Sparkle in Contents/Frameworks (see build_app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
