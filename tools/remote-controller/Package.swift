// swift-tools-version: 6.0
// Foundation-only tests for iPhone Remote Controller, plus an end-to-end pass
// against relay/server.js. Sources are a symlink into App/. SwiftPM rejects a
// target path outside this package.
import PackageDescription

let package = Package(
    name: "remote-controller",
    targets: [
        .target(name: "LojoRemote"),
        .testTarget(
            name: "LojoRemoteTests",
            dependencies: ["LojoRemote"]
        ),
        .testTarget(
            name: "RelayEndToEndTests",
            dependencies: ["LojoRemote"]
        ),
    ]
)
