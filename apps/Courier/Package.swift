// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Courier",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "Courier", targets: ["Courier"]),
        .executable(name: "courier-mcp", targets: ["CourierMCP"]),
        .executable(name: "CourierMobile", targets: ["CourierMobile"]),
        .library(name: "CourierCore", targets: ["CourierCore"]),
    ],
    targets: [
        // Mail without UI: autoconfig, IMAP, MIME, local SQLite cache, Keychain. Shared by the app and the MCP server.
        .target(name: "CourierCore", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedLibrary("sqlite3")]),
        // The mail app: projects board, mailboxes, message list and reader.
        .executableTarget(name: "Courier", dependencies: ["CourierCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // iPhone app (iOS only; on macOS it builds to a stub). Bundled by build-ios.sh.
        .executableTarget(name: "CourierMobile", dependencies: ["CourierCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // stdio MCP server: reads the cache directly, asks the running app (Unix socket) for anything that needs the network.
        .executableTarget(name: "CourierMCP", dependencies: ["CourierCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CourierCoreTests", dependencies: ["CourierCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
