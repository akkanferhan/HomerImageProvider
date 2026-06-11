// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomerImageProvider",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "HomerImageProvider",
            targets: ["HomerImageProvider"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/akkanferhan/HomerFoundation.git", from: "0.5.0"),
        .package(url: "https://github.com/akkanferhan/HomerUIKit.git", from: "0.8.0")
    ],
    targets: [
        .target(
            name: "HomerImageProvider",
            dependencies: [
                .product(name: "HomerFoundation", package: "HomerFoundation"),
                .product(name: "HomerUIKit", package: "HomerUIKit")
            ]
        ),
        .testTarget(
            name: "HomerImageProviderTests",
            dependencies: ["HomerImageProvider"]
        )
    ],
    swiftLanguageModes: [.v6]
)
