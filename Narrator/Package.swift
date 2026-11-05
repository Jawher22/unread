// swift-tools-version: 6.2
// Unread's narrator voice (#57): Qwen3-TTS on MLX, in its own process.
// Build with scripts/build-narrator.sh (Xcode's Swift 6.3+: mlx-swift needs it).
import PackageDescription

let package = Package(
    name: "UnreadNarrator",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/Neywa-Labs/mlx-audio-swift", revision: "927d4e30cf1dd3bcfdbf2cec8c9a6fd7edf4b4fe"),
        // Must match the mlx.metallib scripts/build-narrator.sh fetches (mlx 0.32.4).
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.33.0"),
    ],
    targets: [
        .executableTarget(
            name: "unread-narrator",
            dependencies: [
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        )
    ]
)
