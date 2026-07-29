// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Buoy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BuoyCore", targets: ["BuoyCore"]),
        .executable(name: "BuoyApp", targets: ["BuoyApp"]),
        .executable(name: "buoyctl", targets: ["BuoyCtl"]),
    ],
    targets: [
        .target(
            name: "BuoyCore",
            path: "Sources/BuoyCore"
        ),
        .executableTarget(
            name: "BuoyApp",
            dependencies: ["BuoyCore"],
            path: "Sources/BuoyApp"
        ),
        .executableTarget(
            name: "BuoyCtl",
            dependencies: ["BuoyCore"],
            path: "Sources/BuoyCtl"
        ),
        .testTarget(
            name: "BuoyCoreTests",
            dependencies: ["BuoyCore"],
            path: "Tests/BuoyCoreTests"
        ),
        .testTarget(
            name: "BuoyAppTests",
            dependencies: ["BuoyApp"],
            path: "Tests/BuoyAppTests"
        ),
    ]
)
