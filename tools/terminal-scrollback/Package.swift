// swift-tools-version: 6.0
// Unit tests for terminal scrollback. Foundation only — no SwiftNIO or SwiftTerm.
// Sources and tests are symlinks into App/. SwiftPM rejects a target path outside this package.
import PackageDescription

let package = Package(
    name: "terminal-scrollback",
    targets: [
        .target(name: "LojoTerminalScroll"),
        .testTarget(
            name: "LojoTerminalScrollTests",
            dependencies: ["LojoTerminalScroll"]
        ),
    ]
)
