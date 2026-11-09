// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Hangar",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Hangar", targets: ["Hangar"])],
    targets: [
        // A Dock app that lists my own apps (com.lockedin.*) and opens them.
        .executableTarget(name: "Hangar", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
