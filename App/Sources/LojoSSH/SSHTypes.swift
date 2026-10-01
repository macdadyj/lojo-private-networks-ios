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

/// What happened during user authentication, so a denial can say exactly why.
public struct AuthFailure: Sendable, Equatable, CustomStringConvertible {
    public var username: String
    /// Methods from the server's last USERAUTH_FAILURE ("publickey", "password", ...); nil if it never sent one.
    public var serverMethods: [String]?
    /// `SHA256:` fingerprints of keys the server refused.
    public var rejectedKeys: [String] = []
    /// Keys not offered because the server does not accept publickey.
    public var skippedKeys = 0
    public var passwordRejected = false
    public var passwordCancelled = false
    /// The server hung up mid-authentication (usually sshd's MaxAuthTries).
    public var serverClosed = false
    /// Keys and passwords the app had for this host.
    public var credentialCount = 0

    public init(username: String) {
        self.username = username
    }

    public var acceptsKeys: Bool { serverMethods?.contains("publickey") ?? true }

    public var description: String {
        var parts: [String] = []
        if serverClosed {
            parts.append("the server closed the connection during login (too many keys offered?)")
        }
        if !rejectedKeys.isEmpty {
            let keys = rejectedKeys.joined(separator: ", ")
            parts.append("\(rejectedKeys.count == 1 ? "key" : "keys") \(keys) not in \(username)’s authorized_keys")
        }
        if skippedKeys > 0 {
            parts.append("the server doesn’t accept keys for \(username)")
        }
        if passwordRejected { parts.append("password rejected") }
        if passwordCancelled { parts.append("password prompt cancelled") }
        if parts.isEmpty {
            parts.append(credentialCount == 0 ? "this iPhone has no SSH key or saved password to offer" : "no key or password the server accepts")
        }
        var text = "Login as \(username) denied: " + parts.joined(separator: "; ")
        if let methods = serverMethods {
            text += " (server accepts: \(methods.isEmpty ? "nothing" : methods.joined(separator: ", ")))"
        }
        return text
    }
}

public enum SSHClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case notOverlay(String)
    case hostKeyRejected
    case authenticationFailed(AuthFailure)
    case connectFailed(String)
    case channelRejected(String)
    case pingTimeout
    case disconnected(String)

    public var isAuthFailure: Bool {
        if case .authenticationFailed = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .notOverlay(let why): return why
        case .hostKeyRejected: return "Host key not trusted"
        case .authenticationFailed(let auth): return auth.description
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
        if let e = error as? NWError {
            switch e {
            case .posix(let code):
                if let why = describe(errno: code.rawValue) { return .connectFailed(why) }
            case .dns(let code):
                return .connectFailed("name lookup failed (DNS error \(code))")
            default:
                break
            }
        }
        #endif
        if let e = error as? NIOSSHError {
            switch e.type {
            case .tcpShutdown, .creatingChannelAfterClosure:
                return .disconnected("the server closed the connection")
            case .keyExchangeNegotiationFailure, .unsupportedVersion:
                return .connectFailed("no SSH algorithms in common with the server")
            case .channelSetupRejected:
                return .channelRejected("the session")
            default:
                return .disconnected("SSH protocol error (\(e.type))")
            }
        }
        if let e = error as? ChannelError {
            switch e {
            case .connectTimeout: return .connectFailed("timed out (host down, or a firewall is dropping packets)")
            case .ioOnClosedChannel, .alreadyClosed, .eof: return .disconnected("connection closed")
            default: return .disconnected(String(describing: e))
            }
        }
        return .connectFailed(String(describing: error))
    }

    static func describe(errno code: Int32) -> String? {
        switch code {
        case ECONNREFUSED: return "nothing is listening on that port (connection refused)"
        case EHOSTUNREACH, ENETUNREACH: return "no route to the host (is the VPN up?)"
        case ENETDOWN: return "the network is down (is the VPN up?)"
        case EHOSTDOWN: return "the host is down"
        case EADDRNOTAVAIL: return "this phone has no address that can reach the host (is the VPN up?)"
        case ETIMEDOUT: return "timed out (host down, or a firewall is dropping packets)"
        case ECONNRESET: return "connection reset"
        default: return nil
        }
    }
}
