// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CCUsageTracker",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CCUsageTracker",
            path: "Sources/CCUsageTracker",
            resources: [
                // None yet. Assets.xcassets would go here when wrapping as .app.
            ]
        )
    ]
)
