// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoiceInput", targets: ["VoiceInput"]),
    ],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            dependencies: [],
            path: "Sources/VoiceInput",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
