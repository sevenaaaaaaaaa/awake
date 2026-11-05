// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Awake", targets: ["Awake"]),
        .library(name: "AwakeCore", targets: ["AwakeCore"])
    ],
    targets: [
        .target(
            name: "AwakeCore",
            path: "Sources/AwakeCore",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Awake",
            dependencies: ["AwakeCore"],
            path: "Sources/Awake",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AwakeTests",
            dependencies: ["AwakeCore"],
            path: "Tests/AwakeTests",
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
