// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "RateKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RateKit", targets: ["RateKit"]),
        .executable(name: "ratefeed", targets: ["ratefeed"])
    ],
    dependencies: [],
    targets: [
        .target(name: "RateKit", dependencies: [], resources: [.process("Resources")]),
        .executableTarget(name: "ratefeed", dependencies: ["RateKit"]),
        .testTarget(
            name: "RateKitTests",
            dependencies: ["RateKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
