// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeepSeekKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DeepSeekCore", targets: ["DeepSeekCore"]),
        .library(name: "DeepSeekUI", targets: ["DeepSeekUI"])
    ],
    targets: [
        .target(
            name: "DeepSeekCore",
            path: "Sources/DeepSeekCore"
        ),
        .target(
            name: "DeepSeekUI",
            dependencies: ["DeepSeekCore"],
            path: "Sources/DeepSeekUI"
        ),
        .testTarget(
            name: "DeepSeekCoreTests",
            dependencies: ["DeepSeekCore"],
            path: "Tests/DeepSeekCoreTests"
        )
    ]
)
