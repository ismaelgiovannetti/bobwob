// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BobWob",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BobWobCore", targets: ["BobWobCore"]),
        .executable(name: "bobwob", targets: ["bobwob"]),
        .executable(name: "BobWobApp", targets: ["BobWobApp"]),
    ],
    targets: [
        .target(name: "BobWobCore"),
        .executableTarget(name: "bobwob", dependencies: ["BobWobCore"]),
        .executableTarget(name: "BobWobApp", dependencies: ["BobWobCore"]),
        .testTarget(name: "BobWobCoreTests", dependencies: ["BobWobCore"]),
    ]
)
