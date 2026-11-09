// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Herald",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Herald", targets: ["Herald"])],
    targets: [
        // LinkedIn network and outreach across projects. Data from the linkedin-mcp server (127.0.0.1:47332).
        .executableTarget(name: "Herald", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
