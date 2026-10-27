// swift-tools-version:5.9
import PackageDescription

// SwiftTerm 1.17.0 (MIT), vendored because the upstream repository returns 404 from CI. Reduced to the macOS
// library: no iOS sources, no Metal shader (the GPU renderer is experimental and off by default), no tools or tests.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md"],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
    ],
    swiftLanguageVersions: [.v5]
)
