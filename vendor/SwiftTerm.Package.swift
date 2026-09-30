// swift-tools-version:5.9
// Replaces SwiftTerm's upstream manifest in the pinned checkout. Upstream excludes the
// Apple/iOS sources whenever the manifest is evaluated on a Linux host, which is always
// the case when cross-compiling for iPhone on santa.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md"]),
    ],
    swiftLanguageVersions: [.v5]
)
