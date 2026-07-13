// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"])
    ],
    dependencies: [
        .package(path: "../XMPKit")
    ],
    targets: [
        .target(name: "AppCore", dependencies: ["XMPKit"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "XMPKit"]),
    ]
)
