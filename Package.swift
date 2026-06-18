// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RazerViperControl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RazerCore", targets: ["RazerCore"]),
        .executable(name: "RazerProbeCLI", targets: ["RazerProbeCLI"])
    ],
    targets: [
        .target(
            name: "RazerCore",
            path: "Sources/RazerCore"
        ),
        .executableTarget(
            name: "RazerProbeCLI",
            dependencies: ["RazerCore"],
            path: "Sources/RazerProbeCLI"
        ),
        .testTarget(
            name: "RazerCoreTests",
            dependencies: ["RazerCore"],
            path: "Tests/RazerCoreTests"
        )
    ]
)
