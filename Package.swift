// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jelto",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "Jelto", targets: ["Jelto"]),
        .executable(name: "conformance-host", targets: ["ConformanceHost"]),
    ],
    targets: [
        .target(name: "Jelto"),
        .executableTarget(name: "ConformanceHost", dependencies: ["Jelto"]),
        .testTarget(name: "JeltoTests", dependencies: ["Jelto"]),
    ]
)
