// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUnlimited",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUnlimited", targets: ["ClaudeUnlimited"]),
        .executable(name: "claude-unlimited", targets: ["claude-unlimited"]),
        .library(name: "ClaudeUnlimitedKit", targets: ["ClaudeUnlimitedKit"]),
    ],
    targets: [
        .target(name: "ClaudeUnlimitedKit"),
        .executableTarget(name: "ClaudeUnlimited", dependencies: ["ClaudeUnlimitedKit"]),
        .executableTarget(name: "claude-unlimited", dependencies: ["ClaudeUnlimitedKit"]),
        .testTarget(name: "ClaudeUnlimitedKitTests", dependencies: ["ClaudeUnlimitedKit"]),
    ]
)
