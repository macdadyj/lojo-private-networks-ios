// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LojoNetworks",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LojoNetworks",
            targets: ["LojoNetworks"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        // Pinned SwiftTerm checkout with our manifest, created by scripts/sync-app.sh.
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .target(
            name: "LojoSSH",
            dependencies: [
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(name: "LojoTrust"),
        .target(name: "LojoTerminalScroll"),
        .target(name: "LojoRemote"),
        .target(
            name: "LojoNetworks",
            dependencies: [
                "LojoTrust",
                "LojoSSH",
                "LojoTerminalScroll",
                "LojoRemote",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "LojoTrustTests",
            dependencies: ["LojoTrust"]
        ),
    ]
)
