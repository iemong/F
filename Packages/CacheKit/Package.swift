// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CacheKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CacheKit", targets: ["CacheKit"])
    ],
    targets: [
        .target(name: "CacheKit"),
        .testTarget(name: "CacheKitTests", dependencies: ["CacheKit"]),
    ]
)
