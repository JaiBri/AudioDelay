// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioDelay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AudioDelay", targets: ["AudioDelay"])
    ],
    targets: [
        .executableTarget(
            name: "AudioDelay",
            path: "Sources/AudioDelay"
        ),
        .testTarget(
            name: "AudioDelayTests",
            dependencies: ["AudioDelay"],
            path: "Tests/AudioDelayTests"
        )
    ]
)
