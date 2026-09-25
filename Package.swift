// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeProfiles", targets: ["ClaudeProfiles"]),
        .executable(name: "claude-profiles", targets: ["claude-profiles"]),
        .library(name: "ClaudeProfilesKit", targets: ["ClaudeProfilesKit"]),
    ],
    targets: [
        .target(name: "ClaudeProfilesKit"),
        .executableTarget(name: "ClaudeProfiles", dependencies: ["ClaudeProfilesKit"]),
        .executableTarget(name: "claude-profiles", dependencies: ["ClaudeProfilesKit"]),
        .testTarget(name: "ClaudeProfilesKitTests", dependencies: ["ClaudeProfilesKit"]),
    ]
)
