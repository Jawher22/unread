// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unread",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "ee78635d23d52379117554ba72358b65a0612447")
    ],
    targets: [
        .executableTarget(
            name: "Unread",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "QwenANE"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Gloam Voice Studio's Qwen3-TTS Neural Engine runtime, vendored (MIT). See Vendor/QwenANE/README.md.
        .target(
            name: "QwenANE",
            path: "Vendor/QwenANE/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
