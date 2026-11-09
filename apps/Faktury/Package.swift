// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Faktury",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Faktury", targets: ["Faktury"]),
        .executable(name: "faktury-mcp", targets: ["FakturyMCP"]),
        .library(name: "FakturyCore", targets: ["FakturyCore"]),
    ],
    targets: [
        // Declarations for the system liblzma (in the macOS SDK without headers): raw LZMA1 for PAY by square.
        .target(name: "CLZMA", linkerSettings: [.linkedLibrary("lzma")]),
        // Invoices without UI: SQLite store, numbering, VAT, validation, PDF, PAY by square, company lookup, backup, Courier hand-off.
        .target(name: "FakturyCore", dependencies: ["CLZMA"], swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // The app: subjects, clients, invoices with a live PDF preview.
        .executableTarget(name: "Faktury", dependencies: ["FakturyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // stdio MCP server over the same database (works while the app is closed).
        .executableTarget(name: "FakturyMCP", dependencies: ["FakturyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FakturyCoreTests", dependencies: ["FakturyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
