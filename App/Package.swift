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
    targets: [
        .target(
            name: "LojoNetworks"
        ),
    ]
)
