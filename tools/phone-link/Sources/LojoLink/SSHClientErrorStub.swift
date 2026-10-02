import Foundation

/// Stand-in for `App/Sources/LojoSSH/SSHTypes.swift` so `OverlayPolicy.resolve` compiles here
/// without SwiftNIO. The app target uses the real `SSHClientError`; only `.notOverlay` is thrown
/// from the policy file.
public enum SSHClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case notOverlay(String)

    public var description: String {
        switch self {
        case .notOverlay(let why): return why
        }
    }
}
