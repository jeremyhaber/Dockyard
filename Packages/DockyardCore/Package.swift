// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DockyardCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DockyardCore", targets: ["DockyardCore"]),
    ],
    dependencies: [
        .package(path: "../ConnectionKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "DockyardCore",
            dependencies: [
                .product(name: "ConnectionKit", package: "ConnectionKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "DockyardCoreTests",
            dependencies: ["DockyardCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
