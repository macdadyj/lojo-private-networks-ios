import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
#if canImport(Network)
import Network
#endif

public struct SSHTarget: Sendable, Hashable {
    /// IPv4 literal that already passed `OverlayPolicy`.
    public var address: String
    public var port: Int
    public var username: String

    public init(address: String, port: Int, username: String) {
        self.address = address
        self.port = port
        self.username = username
    }
}

public enum SSHCredential: Sendable {
    case key(NIOSSHPrivateKey)
    case password(String)
}

/// Server host key as presented during key exchange.
public struct HostKeyInfo: Sendable, Hashable {
    public let type: String
    public let base64: String
    /// OpenSSH-style `SHA256:` fingerprint of the key blob, unpadded base64.
    public let fingerprint: String

    public init(_ key: NIOSSHPublicKey) {
        let parts = String(openSSHPublicKey: key).split(separator: " ")
        self.init(type: parts.first.map(String.init) ?? "", base64: parts.count > 1 ? String(parts[1]) : "")
    }

    public init(type: String, base64: String) {
        self.type = type
        self.base64 = base64
        self.fingerprint = HostKeyInfo.fingerprint(ofBase64Blob: base64)
    }

    public static func fingerprint(ofBase64Blob base64: String) -> String {
        let blob = Data(base64Encoded: base64) ?? Data()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

public struct ShellExit: Sendable, Equatable {
    public var status: Int?
    public var signal: String?
    public var error: SSHClientError?

    public var isClean: Bool { error == nil && (status != nil || signal != nil) }
}

public enum SSHClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case notOverlay(String)
    case hostKeyRejected
    case authenticationFailed
    case connectFailed(String)
    case channelRejected(String)
    case pingTimeout
    case disconnected(String)

    public var description: String {
        switch self {
        case .notOverlay(let why): return why
        case .hostKeyRejected: return "Host key not trusted"
        case .authenticationFailed: return "Authentication failed (key or password not accepted)"
        case .connectFailed(let why): return "Can’t connect: \(why)"
        case .channelRejected(let what): return "Server refused \(what)"
        case .pingTimeout: return "Connection stopped responding"
        case .disconnected(let why): return "Disconnected: \(why)"
        }
    }

    static func wrap(_ error: Error) -> SSHClientError {
        if let e = error as? SSHClientError { return e }
        if let e = error as? NIOConnectionError, let first = e.connectionErrors.first?.error {
            return wrap(first)
        }
        if let e = error as? IOError, let why = describe(errno: e.errnoCode) {
            return .connectFailed(why)
        }
        #if canImport(Network)
        if let e = error as? NWError, case .posix(let code) = e, let why = describe(errno: code.rawValue) {
            return .connectFailed(why)
        }
        #endif
        if let e = error as? ChannelError {
            switch e {
            case .connectTimeout: return .connectFailed("timed out")
            case .ioOnClosedChannel, .alreadyClosed, .eof: return .disconnected("connection closed")
            default: return .disconnected(String(describing: e))
            }
        }
        return .connectFailed(String(describing: error))
    }

    private static func describe(errno code: Int32) -> String? {
        switch code {
        case ECONNREFUSED: return "nothing is listening on that port (connection refused)"
        case EHOSTUNREACH, ENETUNREACH: return "no route to the host (is the VPN up?)"
        case ETIMEDOUT: return "timed out"
        case ECONNRESET: return "connection reset"
        default: return nil
        }
    }
}
