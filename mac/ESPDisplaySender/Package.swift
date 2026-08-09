// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ESPDisplaySender",
    platforms: [
        // macOS 26 is the floor because the window is built out of Liquid Glass
        // components - glassEffect, GlassEffectContainer, ToolbarSpacer, the
        // glass button styles - none of which exist before it. Written as a
        // version string rather than `.macOS(.v26)` so swift-tools-version can
        // stay at 5.9: bumping it to 6.x would also switch the package into the
        // Swift 6 language mode, which is a separate migration.
        .macOS("26.0")
    ],
    products: [
        .library(name: "SenderProtocol", targets: ["SenderProtocol"]),
        .library(name: "SenderCore", targets: ["SenderCore"]),
        .executable(name: "ESPDisplaySender", targets: ["ESPDisplaySender"]),
    ],
    targets: [
        .target(
            name: "SenderProtocol",
            path: "Sources/SenderProtocol"
        ),
        // The application layer: capture, streaming, discovery, persistence,
        // and UI. A library rather than part of the executable so tests can
        // import it - executable targets cannot be imported.
        .target(
            name: "SenderCore",
            dependencies: ["SenderProtocol"],
            path: "Sources/SenderCore"
        ),
        .executableTarget(
            name: "ESPDisplaySender",
            dependencies: ["SenderCore"],
            path: "Sources/ESPDisplaySender"
        ),
        .testTarget(
            name: "SenderProtocolTests",
            dependencies: ["SenderProtocol"],
            path: "Tests/SenderProtocolTests"
        ),
        .testTarget(
            name: "SenderCoreTests",
            dependencies: ["SenderCore"],
            path: "Tests/SenderCoreTests"
        ),
    ]
)
