// swift-tools-version: 6.0
// Host-side tests for the certificate profile check the iOS app uses.
// The app package also builds this target; this manifest avoids the iOS-only dependencies.
import PackageDescription

let package = Package(
    name: "tls-trust",
    targets: [
        .target(name: "LojoTrust"),
        .testTarget(name: "LojoTrustTests", dependencies: ["LojoTrust"]),
    ]
)
