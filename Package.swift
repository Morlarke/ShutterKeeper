// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShutterKeeper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ShutterKeeper", targets: ["ShutterKeeperApp"]),
        .executable(name: "skctl", targets: ["ShutterKeeperCLI"]),
        .library(name: "ShutterKeeperCore", targets: ["ShutterKeeperCore"]),
    ],
    targets: [
        .target(
            name: "ShutterKeeperCore",
            path: "Sources/ShutterKeeperCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ShutterKeeperApp",
            dependencies: ["ShutterKeeperCore"],
            path: "Sources/ShutterKeeperApp"
        ),
        .executableTarget(
            name: "ShutterKeeperCLI",
            dependencies: ["ShutterKeeperCore"],
            path: "Sources/ShutterKeeperCLI"
        ),
        .testTarget(
            name: "ShutterKeeperCoreTests",
            dependencies: ["ShutterKeeperCore"],
            path: "Tests/ShutterKeeperCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
