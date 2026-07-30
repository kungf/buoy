// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenRunway",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenRunwayCore", targets: ["TokenRunwayCore"]),
        .executable(name: "TokenRunwayApp", targets: ["TokenRunwayApp"]),
        .executable(name: "trwyctl", targets: ["TokenRunwayCtl"]),
    ],
    targets: [
        .target(
            name: "TokenRunwayCore",
            path: "Sources/TokenRunwayCore"
        ),
        .executableTarget(
            name: "TokenRunwayApp",
            dependencies: ["TokenRunwayCore"],
            path: "Sources/TokenRunwayApp"
        ),
        .executableTarget(
            name: "TokenRunwayCtl",
            dependencies: ["TokenRunwayCore"],
            path: "Sources/TokenRunwayCtl"
        ),
        .testTarget(
            name: "TokenRunwayCoreTests",
            dependencies: ["TokenRunwayCore"],
            path: "Tests/TokenRunwayCoreTests"
        ),
        .testTarget(
            name: "TokenRunwayAppTests",
            dependencies: ["TokenRunwayApp"],
            path: "Tests/TokenRunwayAppTests"
        ),
    ]
)
