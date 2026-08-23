// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AutoDuck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AutoDuck",
            path: "Sources/AutoDuck"
        )
    ]
)
