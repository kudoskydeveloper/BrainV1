// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Meetings",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Meetings", targets: ["Meetings"])],
    targets: [
        // Recorded meetings (Fathom notes) and upcoming ones with prep. Data from Brain (`brain meetings`, `brain meeting-prep`).
        .executableTarget(name: "Meetings", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
