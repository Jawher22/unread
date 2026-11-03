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
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
