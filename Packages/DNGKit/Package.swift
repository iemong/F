// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DNGKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DNGKit", targets: ["DNGKit"]),
        .executable(name: "dngdump", targets: ["dngdump"]),
    ],
    targets: [
        .target(name: "DNGKit"),
        .executableTarget(name: "dngdump", dependencies: ["DNGKit"]),
        .testTarget(name: "DNGKitTests", dependencies: ["DNGKit"]),
    ]
)
