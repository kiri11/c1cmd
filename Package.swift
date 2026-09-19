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
        ),
        .executable(
            name: "c1-mcp",
            targets: ["c1-mcp"]
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
        ),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            from: "0.12.1"
        )
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "CaptureOneCore",
            dependencies: [
                "CSQLite",
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
            name: "c1-mcp",
            dependencies: [
                "CaptureOneCore",
                .product(name: "MCP", package: "swift-sdk")
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
