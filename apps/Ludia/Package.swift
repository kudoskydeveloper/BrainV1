// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Ludia",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Ludia", targets: ["Ludia"])],
    targets: [
        // Personal CRM: people, last contact on every channel, who to get in touch with. Data from Brain (`brain ludia`).
        .executableTarget(name: "Ludia", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
