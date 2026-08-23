// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MrAutoDuck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MrAutoDuck",
            path: "Sources/MrAutoDuck"
        )
    ]
)
