// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LumixKit",
    platforms: [.macOS("14.1")],
    products: [
        .library(name: "LumixProtocol", targets: ["LumixProtocol"]),
    ],
    targets: [
        .target(name: "LumixProtocol"),
        .testTarget(name: "LumixProtocolTests", dependencies: ["LumixProtocol"]),
    ]
)
