import Crypto
import Foundation
import NIOSSH

/// Private key parsed from pasted text. Only lives in memory until it goes into the Keychain.
public enum ImportedKey: Sendable {
    case ed25519(Curve25519.Signing.PrivateKey, comment: String)
    case p256(P256.Signing.PrivateKey, comment: String)

    public var sshKey: NIOSSHPrivateKey {
        switch self {
        case .ed25519(let k, _): return NIOSSHPrivateKey(ed25519Key: k)
        case .p256(let k, _): return NIOSSHPrivateKey(p256Key: k)
        }
    }

    public var comment: String {
        switch self {
        case .ed25519(_, let c), .p256(_, let c): return c
        }
    }
}

public enum KeyImportError: Error, Equatable, CustomStringConvertible {
    case unrecognized
    case encrypted
    case unsupportedType(String)
    case malformed

    public var description: String {
        switch self {
        case .unrecognized: return "Not an OpenSSH or PEM private key"
        case .encrypted: return "Passphrase-protected keys aren’t supported yet. Generate a key on the phone instead."
        case .unsupportedType(let t): return "Key type \(t) isn’t supported (use Ed25519 or ECDSA P-256)"
        case .malformed: return "The key text is damaged or incomplete"
        }
    }
}

public enum KeyImport {
    public static func parse(_ text: String) throws -> ImportedKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSH(trimmed)
        }
        if trimmed.contains("ENCRYPTED") { throw KeyImportError.encrypted }
        if trimmed.contains("BEGIN EC PRIVATE KEY") || trimmed.contains("BEGIN PRIVATE KEY") {
            guard let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) else {
                throw KeyImportError.unsupportedType("in this PEM file")
            }
            return .p256(key, comment: "")
        }
        throw KeyImportError.unrecognized
    }

    /// openssh-key-v1 (PROTOCOL.key), unencrypted, single key.
    static func parseOpenSSH(_ pem: String) throws -> ImportedKey {
        let body = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw KeyImportError.malformed }
        var r = Reader(Array(data))
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard try r.bytes(magic.count) == magic else { throw KeyImportError.malformed }
        let cipher = try r.string()
        let kdf = try r.string()
        _ = try r.blob()
        guard cipher == "none", kdf == "none" else { throw KeyImportError.encrypted }
        guard try r.uint32() == 1 else { throw KeyImportError.unsupportedType("bundles with several keys") }
        _ = try r.blob()
        var p = Reader(try r.blob())
        let check1 = try p.uint32()
        let check2 = try p.uint32()
        guard check1 == check2 else { throw KeyImportError.malformed }
        let type = try p.string()
        switch type {
        case "ssh-ed25519":
            _ = try p.blob()
            let secret = try p.blob()
            guard secret.count == 64 else { throw KeyImportError.malformed }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
            return .ed25519(key, comment: try p.string())
        case "ecdsa-sha2-nistp256":
            guard try p.string() == "nistp256" else { throw KeyImportError.malformed }
            _ = try p.blob()
            var scalar = try p.blob()
            while scalar.count > 32, scalar.first == 0 { scalar.removeFirst() }
            guard scalar.count <= 32 else { throw KeyImportError.malformed }
            let padded = [UInt8](repeating: 0, count: 32 - scalar.count) + scalar
            let key = try P256.Signing.PrivateKey(rawRepresentation: padded)
            return .p256(key, comment: try p.string())
        default:
            throw KeyImportError.unsupportedType(type)
        }
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, offset + n <= bytes.count else { throw KeyImportError.malformed }
            defer { offset += n }
            return Array(bytes[offset..<offset + n])
        }

        mutating func uint32() throws -> UInt32 {
            try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func blob() throws -> [UInt8] {
            try bytes(Int(uint32()))
        }

        mutating func string() throws -> String {
            String(decoding: try blob(), as: UTF8.self)
        }
    }
}

extension NIOSSHPrivateKey {
    /// `type base64 comment`, ready for authorized_keys.
    public func authorizedKeysLine(comment: String) -> String {
        let line = String(openSSHPublicKey: publicKey)
        return comment.isEmpty ? line : "\(line) \(comment)"
    }
}
