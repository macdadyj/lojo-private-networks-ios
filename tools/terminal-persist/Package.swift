// swift-tools-version: 6.0
// Unit tests for tmux command construction and the terminal reconnect state machine.
// These sources are Foundation-only, so this package does not fetch SwiftNIO or SwiftTerm.
import PackageDescription

let package = Package(
    name: "terminal-persist",
    targets: [
        .target(name: "TerminalPersist"),
        .testTarget(name: "TerminalPersistTests", dependencies: ["TerminalPersist"]),
    ]
)
