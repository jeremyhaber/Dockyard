// swift-tools-version:6.0
import PackageDescription

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
]

// macOS has no system libssh2: use a prebuilt libssh2 + OpenSSL xcframework (module CSSH).
// On Linux the CLibSSH2 system library target links the distro's libssh2 through pkg-config.
#if os(macOS)
dependencies.append(.package(url: "https://github.com/DimaRU/Libssh2Prebuild.git", exact: "1.11.0-OpenSSL-1-1-1w"))
let libssh2Dependencies: [Target.Dependency] = [.product(name: "CSSH", package: "Libssh2Prebuild", condition: .when(platforms: [.macOS]))]
#else
let libssh2Dependencies: [Target.Dependency] = [.target(name: "CLibSSH2", condition: .when(platforms: [.linux]))]
#endif

let package = Package(
    name: "ConnectionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConnectionKit", targets: ["ConnectionKit"]),
    ],
    dependencies: dependencies,
    targets: [
        .systemLibrary(
            name: "CLibSSH2",
            pkgConfig: "libssh2",
            providers: [.apt(["libssh2-1-dev"]), .brew(["libssh2"])]
        ),
        .target(
            name: "ConnectionKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ] + libssh2Dependencies
        ),
        .testTarget(
            name: "ConnectionKitTests",
            dependencies: ["ConnectionKit", .product(name: "Crypto", package: "swift-crypto")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
