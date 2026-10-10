// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LumixKit",
    platforms: [.macOS("14.1")],
    products: [
        .library(name: "LumixProtocol", targets: ["LumixProtocol"]),
        .library(name: "LumixSession", targets: ["LumixSession"]),
    ],
    targets: [
        .target(name: "LumixProtocol"),
        .target(name: "LumixSession", dependencies: ["LumixProtocol"]),
        .target(name: "LumixTestSupport", path: "Tests/LumixTestSupport"),
        .testTarget(name: "LumixProtocolTests", dependencies: ["LumixProtocol", "LumixTestSupport"]),
        .testTarget(name: "LumixSessionTests", dependencies: ["LumixSession", "LumixProtocol", "LumixTestSupport"]),
    ]
)
