// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Fitness",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Fitness", targets: ["Fitness"])],
    targets: [
        // Hevy + Strava + MyFitnessPal in one window, with charts. Data from Brain (`brain fitness --json`).
        .executableTarget(name: "Fitness", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
