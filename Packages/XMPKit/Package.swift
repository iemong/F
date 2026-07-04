// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XMPKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XMPKit", targets: ["XMPKit"])
    ],
    targets: [
        .target(name: "XMPKit"),
        .testTarget(name: "XMPKitTests", dependencies: ["XMPKit"]),
    ]
)
