// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "M0BridgeProbe", platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/emorydunn/AppleScriptBridge.git",
        revision: "58946d7fd5b38b6a92c13ccb413d30ba1f0e9179")],
    targets: [.executableTarget(name: "M0BridgeProbe", dependencies: ["AppleScriptBridge"])])
