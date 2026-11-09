// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Brain",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Brain", targets: ["Brain"]),
        .library(name: "BrainCore", targets: ["BrainCore"]),
    ],
    targets: [
        // Runs `claude -p` with only the Brain MCP and parses its stream. No UI.
        .target(name: "BrainCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Hotkey panel + menu bar item.
        .executableTarget(name: "Brain", dependencies: ["BrainCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BrainCoreTests", dependencies: ["BrainCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
