// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ESPDisplaySender",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ESPDisplaySender",
            path: "Sources/ESPDisplaySender"
        )
    ]
)
