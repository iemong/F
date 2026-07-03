// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DecodeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DecodeKit", targets: ["DecodeKit"]),
        .executable(name: "decodebench", targets: ["decodebench"]),
    ],
    dependencies: [
        .package(path: "../DNGKit")
    ],
    targets: [
        .target(name: "DecodeKit", dependencies: ["DNGKit"]),
        .executableTarget(name: "decodebench", dependencies: ["DecodeKit", "DNGKit"]),
        .testTarget(name: "DecodeKitTests", dependencies: ["DecodeKit", "DNGKit"]),
    ]
)
