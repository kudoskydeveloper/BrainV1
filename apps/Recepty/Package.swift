// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Recepty",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Recepty", targets: ["Recepty"]),
        .executable(name: "recepty-mcp", targets: ["ReceptyMCP"]),
        .library(name: "ReceptyCore", targets: ["ReceptyCore"]),
    ],
    targets: [
        // Recipes without UI: SQLite store, the bundled USDA food database, Open Food Facts, import from a web page or text,
        // nutrition analysis through the claude CLI, scaling, meal log and plan.
        .target(name: "ReceptyCore", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedLibrary("sqlite3")]),
        // The app: library, recipe with nutrition and portion calculator, cook mode, plan and meal log.
        .executableTarget(name: "Recepty", dependencies: ["ReceptyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // stdio MCP server over the same database (Brain routes to it as `recepty`).
        .executableTarget(name: "ReceptyMCP", dependencies: ["ReceptyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ReceptyCoreTests", dependencies: ["ReceptyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
