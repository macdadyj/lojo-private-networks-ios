// swift-tools-version: 6.0
// Unit tests for terminal scrollback. Foundation only — no SwiftNIO or SwiftTerm.
import PackageDescription

let package = Package(
    name: "terminal-scrollback",
    targets: [
        .target(
            name: "LojoTerminalScroll",
            path: "../../App/Sources/LojoTerminalScroll"
        ),
        .testTarget(
            name: "LojoTerminalScrollTests",
            dependencies: ["LojoTerminalScroll"],
            path: "../../App/Tests/LojoNetworksTests"
        ),
    ]
)
