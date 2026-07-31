// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "aibar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "aibar",
            path: "Sources/aibar",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "aibarTests",
            dependencies: ["aibar"],
            path: "Tests/aibarTests"
        )
    ]
)
