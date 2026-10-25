// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KiteIOSFeature",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "KiteIOSFeature",
            targets: ["KiteIOSFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "KiteIOSFeature",
            dependencies: [
                .product(name: "KiteCore", package: "Kite"),
            ],
            path: "Sources/KiteIOSFeature"
        ),
        .testTarget(
            name: "KiteIOSFeatureTests",
            dependencies: [
                "KiteIOSFeature"
            ]
        ),
    ]
)
