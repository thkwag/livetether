// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LumixKit",
    defaultLocalization: "en",
    platforms: [.macOS("14.1")],
    products: [
        .library(name: "LumixProtocol", targets: ["LumixProtocol"]),
        .library(name: "LumixSession", targets: ["LumixSession"]),
        .library(name: "LumixImageCapture", targets: ["LumixImageCapture"]),
        .library(name: "LumixVideo", targets: ["LumixVideo"]),
        .library(name: "LumixVirtualCamera", targets: ["LumixVirtualCamera"]),
        .executable(name: "lumix-sink-probe", targets: ["lumix-sink-probe"]),
    ],
    targets: [
        .target(name: "LumixProtocol"),
        .target(name: "LumixSession", dependencies: ["LumixProtocol"]),
        .target(name: "LumixImageCapture", dependencies: ["LumixProtocol", "LumixSession"]),
        .target(name: "LumixVideo"),
        .target(name: "LumixVirtualCamera", dependencies: ["LumixVideo", "LumixProtocol", "LumixSession"], resources: [.process("Resources")]),
        .executableTarget(name: "lumix-sink-probe", dependencies: ["LumixVideo", "LumixVirtualCamera"], path: "Tools/SinkProbe"),
        .target(name: "LumixTestSupport", path: "Tests/LumixTestSupport"),
        .testTarget(name: "LumixProtocolTests", dependencies: ["LumixProtocol", "LumixTestSupport"]),
        .testTarget(name: "LumixSessionTests", dependencies: ["LumixSession", "LumixProtocol", "LumixTestSupport"]),
        .testTarget(name: "LumixVideoTests", dependencies: ["LumixVideo", "LumixTestSupport"]),
        .testTarget(name: "LumixVirtualCameraTests", dependencies: ["LumixVirtualCamera", "LumixVideo", "LumixSession", "LumixTestSupport"]),
    ]
)
