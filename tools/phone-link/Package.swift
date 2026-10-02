// swift-tools-version: 6.0
// Host-side tests for overlay interface selection. The iOS app package can't `swift test`
// on Linux (UIKit / SwiftTerm). OverlayPolicy.swift and InterfacePick.swift are symlinked
// from the app; SSHClientErrorStub.swift stands in for the NIO-backed error type so this
// target does not fetch SwiftNIO.
import PackageDescription

let package = Package(
    name: "phone-link",
    targets: [
        .target(name: "LojoLink"),
        .testTarget(name: "LojoLinkTests", dependencies: ["LojoLink"]),
    ]
)
