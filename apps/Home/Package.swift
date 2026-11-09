// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Home",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "Home", targets: ["Home"]),
        .executable(name: "HomeMobile", targets: ["HomeMobile"]),
        .library(name: "HomeCore", targets: ["HomeCore"]),
    ],
    targets: [
        // The household without UI: chores and their schedule, shopping, the local copy and its two-way Supabase sync.
        // Shared by the Mac app, the MCP server and later the iPhone app.
        .target(name: "HomeCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The Mac app: today, chores, shopping, plan, household.
        .executableTarget(name: "Home", dependencies: ["HomeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // iPhone app (iOS only; on macOS it builds to a stub). Bundled by build-ios.sh.
        .executableTarget(name: "HomeMobile", dependencies: ["HomeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HomeCoreTests", dependencies: ["HomeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
