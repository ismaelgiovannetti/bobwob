// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BobWob",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BobWobCore", targets: ["BobWobCore"]),
        .executable(name: "bobwob", targets: ["bobwob"]),
    ],
    targets: [
        .target(name: "BobWobCore"),
        .executableTarget(name: "bobwob", dependencies: ["BobWobCore"]),
        .testTarget(name: "BobWobCoreTests", dependencies: ["BobWobCore"]),
    ]
)
