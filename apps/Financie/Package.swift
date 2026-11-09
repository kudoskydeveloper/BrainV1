// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Financie",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Financie", targets: ["Financie"]),
        .executable(name: "financie-mcp", targets: ["FinancieMCP"]),
        .library(name: "FinancieCore", targets: ["FinancieCore"]),
    ],
    targets: [
        // Money without UI: SQLite store, wallets and accounts, transactions, recurring items and what they expect, reports,
        // forecast, the link to Faktúry (read only) and backups.
        .target(name: "FinancieCore", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedLibrary("sqlite3")]),
        // The app: overview with charts, accounts, transactions, recurring items, what's waiting; locked by Touch ID.
        .executableTarget(name: "Financie", dependencies: ["FinancieCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // stdio MCP server over the same database (works while the app is closed or locked).
        .executableTarget(name: "FinancieMCP", dependencies: ["FinancieCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FinancieCoreTests", dependencies: ["FinancieCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
