// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "c1",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "c1",
            targets: ["c1"]
        )
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "C1Kit",
            dependencies: ["CSQLite"],
            // Built into Generated/Embedded.swift, so c1 is one file with no bundle beside it.
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "c1",
            dependencies: ["C1Kit"]
        ),
        .executableTarget(
            name: "C1KitTests",
            dependencies: ["C1Kit"],
            path: "Tests/C1KitTests"
        )
    ]
)
