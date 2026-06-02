// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MACQ",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "MACQ", targets: ["MicEQ"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "MicEQ",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        ),
    ]
)
