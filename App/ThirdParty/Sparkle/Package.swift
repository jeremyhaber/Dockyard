// swift-tools-version:5.9
import PackageDescription

// Sparkle 2.8.1 (MIT and bundled third-party licences, see LICENSE), the unmodified
// Sparkle-for-Swift-Package-Manager.zip release without its dSYMs. Vendored like SwiftTerm because the upstream
// repository is not reachable from CI. Replace with `https://github.com/sparkle-project/Sparkle`, exact 2.8.1,
// when it is.
let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Sparkle", targets: ["Sparkle"])],
    targets: [
        .binaryTarget(name: "Sparkle", path: "Sparkle.xcframework"),
    ]
)
