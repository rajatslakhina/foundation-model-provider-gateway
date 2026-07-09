// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProviderGatewayKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ProviderGatewayKit",
            targets: ["ProviderGatewayKit"]
        )
    ],
    targets: [
        .target(
            name: "ProviderGatewayKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ProviderGatewayKitTests",
            dependencies: ["ProviderGatewayKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
