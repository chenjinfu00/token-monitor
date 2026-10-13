// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenMonitor", targets: ["TokenMonitor"])],
    targets: [
        .executableTarget(name: "TokenMonitor", linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
