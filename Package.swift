// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CCUsageTracker",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "CCUsageCore",
            path: "Sources/CCUsageCore"
        ),
        .executableTarget(
            name: "CCUsageTracker",
            dependencies: ["CCUsageCore"],
            path: "Sources/CCUsageTracker",
            resources: [
                // None yet. Assets.xcassets would go here when wrapping as .app.
            ]
        ),
        .testTarget(
            name: "CCUsageTrackerTests",
            dependencies: ["CCUsageCore"],
            path: "Tests/CCUsageTrackerTests"
        )
    ]
)