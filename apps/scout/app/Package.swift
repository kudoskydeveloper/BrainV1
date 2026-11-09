// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Scout",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Scout", targets: ["Scout"])],
    targets: [
        // Scout: business CRM over 10T Base and Kuboard. Data from Brain (`brain crm`).
        .executableTarget(name: "Scout", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
