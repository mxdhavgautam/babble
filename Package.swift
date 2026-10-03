// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Babble",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "Babble", path: "Sources/Babble"),
        .testTarget(name: "BabbleTests", dependencies: ["Babble"]),
    ]
)
