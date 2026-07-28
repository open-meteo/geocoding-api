// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "GeocodingApi",
    platforms: [
        .macOS(.v10_15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["ProtoResources/"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
            ],
        ),
        .executableTarget(name: "Run", dependencies: [.target(name: "App")]),
        .testTarget(
            name: "AppTests",
            dependencies: ["App"]
        ),
    ]
)
