// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ESPDisplaySender",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SenderProtocol", targets: ["SenderProtocol"]),
        .executable(name: "ESPDisplaySender", targets: ["ESPDisplaySender"]),
    ],
    targets: [
        .target(
            name: "SenderProtocol",
            path: "Sources/SenderProtocol"
        ),
        .executableTarget(
            name: "ESPDisplaySender",
            dependencies: ["SenderProtocol"],
            path: "Sources/ESPDisplaySender"
        ),
        .testTarget(
            name: "SenderProtocolTests",
            dependencies: ["SenderProtocol"],
            path: "Tests/SenderProtocolTests"
        ),
    ]
)
