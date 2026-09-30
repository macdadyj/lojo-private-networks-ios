import Crypto
import Foundation
import LojoSSH
import NIOSSH
import Security

struct SSHKeyRecord: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case secureEnclaveP256, ed25519, p256

        var title: String {
            switch self {
            case .secureEnclaveP256: return "Secure Enclave · ECDSA P-256"
            case .ed25519: return "Ed25519 · Keychain"
            case .p256: return "ECDSA P-256 · Keychain"
            }
        }
    }

    var id: String
    var label: String
    var kind: Kind
    /// authorized_keys line; public, safe to show and share.
    var publicKey: String
    var created: Date

    var fingerprint: String {
        let parts = publicKey.split(separator: " ")
        return parts.count > 1 ? HostKeyInfo.fingerprint(ofBase64Blob: String(parts[1])) : ""
    }
}

enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    case missing

    var description: String {
        switch self {
        case .status(let s): return "Keychain error \(s)"
        case .missing: return "Key material is missing from the Keychain"
        }
    }
}

/// Private key material lives only in the Keychain, readable while unlocked and never synced or backed
/// up. For Secure Enclave keys it is the SE-wrapped blob, which is useless off this phone's enclave.
/// The metadata list (labels, public keys) is a plain JSON file.
@MainActor
final class SSHKeyStore: ObservableObject {
    @Published private(set) var keys: [SSHKeyRecord] = []

    private static let keyService = "com.lojo.PrivateNetworks.ssh-key"
    private static let passwordService = "com.lojo.PrivateNetworks.ssh-password"
    private let listURL: URL

    init(directory: URL) {
        listURL = directory.appendingPathComponent("keys.json")
        if let data = try? Data(contentsOf: listURL),
           let list = try? JSONDecoder().decode([SSHKeyRecord].self, from: data) {
            keys = list
        }
    }

    var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    @discardableResult
    func generateSecureEnclave(label: String) throws -> SSHKeyRecord {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error
        ) else { throw error!.takeRetainedValue() as Error }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let ssh = NIOSSHPrivateKey(secureEnclaveP256Key: key)
        return try add(label: label, kind: .secureEnclaveP256, secret: key.dataRepresentation, sshKey: ssh)
    }

    @discardableResult
    func generateEd25519(label: String) throws -> SSHKeyRecord {
        let key = Curve25519.Signing.PrivateKey()
        return try add(label: label, kind: .ed25519, secret: key.rawRepresentation, sshKey: NIOSSHPrivateKey(ed25519Key: key))
    }

    @discardableResult
    func importKey(text: String, label: String) throws -> SSHKeyRecord {
        let imported = try KeyImport.parse(text)
        let name = label.isEmpty ? (imported.comment.isEmpty ? "Imported key" : imported.comment) : label
        switch imported {
        case .ed25519(let k, _):
            return try add(label: name, kind: .ed25519, secret: k.rawRepresentation, sshKey: imported.sshKey)
        case .p256(let k, _):
            return try add(label: name, kind: .p256, secret: k.rawRepresentation, sshKey: imported.sshKey)
        }
    }

    func delete(_ record: SSHKeyRecord) {
        SecItemDelete(Self.query(service: Self.keyService, account: record.id) as CFDictionary)
        keys.removeAll { $0.id == record.id }
        persist()
    }

    func privateKey(_ record: SSHKeyRecord) throws -> NIOSSHPrivateKey {
        let secret = try Self.read(service: Self.keyService, account: record.id)
        switch record.kind {
        case .secureEnclaveP256:
            return NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret))
        case .ed25519:
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret))
        case .p256:
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: secret))
        }
    }

    // MARK: Passwords (only when the owner asks to save one)

    func password(hostID: UUID) -> String? {
        (try? Self.read(service: Self.passwordService, account: hostID.uuidString)).map { String(decoding: $0, as: UTF8.self) }
    }

    func savePassword(_ password: String, hostID: UUID) {
        try? Self.write(Data(password.utf8), service: Self.passwordService, account: hostID.uuidString)
    }

    func forgetPassword(hostID: UUID) {
        SecItemDelete(Self.query(service: Self.passwordService, account: hostID.uuidString) as CFDictionary)
    }

    // MARK: Private

    private func add(label: String, kind: SSHKeyRecord.Kind, secret: Data, sshKey: NIOSSHPrivateKey) throws -> SSHKeyRecord {
        let id = UUID().uuidString
        let comment = label.replacingOccurrences(of: " ", with: "-") + "@lojo-iphone"
        try Self.write(secret, service: Self.keyService, account: id)
        let record = SSHKeyRecord(id: id, label: label, kind: kind, publicKey: sshKey.authorizedKeysLine(comment: comment), created: Date())
        keys.append(record)
        persist()
        return record
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(keys) {
            try? data.write(to: listURL, options: [.atomic, .completeFileProtection])
        }
        #if DEBUG
        // Public halves only, so a USB-attached dev machine can add them to a test authorized_keys.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let lines = keys.map(\.publicKey).joined(separator: "\n")
        try? (lines + "\n").write(to: documents.appendingPathComponent("lojo-ssh-public-keys.txt"), atomically: true, encoding: .utf8)
        #endif
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func write(_ data: Data, service: String, account: String) throws {
        let base = query(service: service, account: account)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func read(service: String, account: String) throws -> Data {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            throw status == errSecItemNotFound ? KeychainError.missing : KeychainError.status(status)
        }
        return data
    }
}
