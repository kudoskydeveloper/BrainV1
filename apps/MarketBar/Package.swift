// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MarketBar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MarketBar", targets: ["MarketBar"]),
        .library(name: "MarketCore", targets: ["MarketCore"]),
    ],
    targets: [
        // Alpaca REST + live stream, config shared with ~/Developer/market-alerts, alert rules, brief text. No UI.
        .target(name: "MarketCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The menu bar app: SwiftUI + Swift Charts.
        .executableTarget(name: "MarketBar", dependencies: ["MarketCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MarketCoreTests", dependencies: ["MarketCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
