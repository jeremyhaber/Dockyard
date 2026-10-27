// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RcloneKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RcloneKit", targets: ["RcloneKit"]),
    ],
    dependencies: [
        .package(path: "../ConnectionKit"),
    ],
    targets: [
        .target(name: "CRclone"),
        .target(
            name: "RcloneKit",
            dependencies: ["CRclone", "ConnectionKit"]
        ),
        .testTarget(
            name: "RcloneKitTests",
            dependencies: ["RcloneKit", "ConnectionKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
