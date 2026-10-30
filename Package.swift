// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SystemAudioPassThrough",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "SystemAudioPassThrough", targets: ["SystemAudioPassThrough"])
    ],
    targets: [
        .target(name: "AudioMetrics", publicHeadersPath: "include"),
        .target(name: "PrototypeSupport", path: "Sources/PrototypeSupport"),
        .target(name: "LevelUpDSP", path: "Sources/LevelUpDSP"),
        .executableTarget(
            name: "SystemAudioPassThrough",
            dependencies: ["AudioMetrics", "PrototypeSupport", "LevelUpDSP"],
            path: "Sources/SystemAudioPassThrough"
        ),
        .testTarget(
            name: "SystemAudioPassThroughTests",
            dependencies: ["AudioMetrics", "PrototypeSupport", "LevelUpDSP"],
            path: "Tests/SystemAudioPassThroughTests"
        )
    ]
)
