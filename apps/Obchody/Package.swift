// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Obchody",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Obchody", targets: ["Obchody"])],
    targets: [
        // Obchody: business CRM over 10T Base and Kuboard. Data from Brain (`brain crm`).
        .executableTarget(name: "Obchody", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
