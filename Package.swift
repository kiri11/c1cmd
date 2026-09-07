// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "c1",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CaptureOneCore",
            targets: ["CaptureOneCore"]
        ),
        .executable(
            name: "c1",
            targets: ["c1"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/emorydunn/AppleScriptBridge.git",
            revision: "58946d7fd5b38b6a92c13ccb413d30ba1f0e9179"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.3.0"
        )
    ],
    targets: [
        .target(
            name: "CaptureOneCore",
            dependencies: [
                .product(name: "AppleScriptBridge", package: "AppleScriptBridge")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "c1",
            dependencies: [
                "CaptureOneCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "CaptureOneCoreTests",
            dependencies: [
                "CaptureOneCore"
            ],
            path: "Tests/CaptureOneCoreTests"
        )
    ]
)
