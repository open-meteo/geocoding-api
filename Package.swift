// swift-tools-version:6.4

import PackageDescription

let package = Package(
    name: "GeocodingApi",
    platforms: [
        .macOS("26.2")
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", exact: "5.0.0-beta.4", traits: []),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["ProtoResources/"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ],
        ),
        .executableTarget(
            name: "Run",
            dependencies: [
                .target(name: "App"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["App", .product(name: "VaporTesting", package: "vapor")]
        ),
    ]
)
