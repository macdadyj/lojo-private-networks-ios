// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RanchField",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RanchField",
            targets: ["RanchField"]
        ),
    ],
    targets: [
        .target(
            name: "RanchField"
        ),
    ]
)
