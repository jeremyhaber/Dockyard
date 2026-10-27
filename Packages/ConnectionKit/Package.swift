// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ConnectionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConnectionKit", targets: ["ConnectionKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "ConnectionKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "ConnectionKitTests",
            dependencies: ["ConnectionKit", .product(name: "Crypto", package: "swift-crypto")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
