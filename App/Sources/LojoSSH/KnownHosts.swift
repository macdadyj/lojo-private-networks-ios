import Foundation

/// Plain (unhashed) OpenSSH known_hosts: `host[,host…] keytype base64 [comment]`.
public struct KnownHosts: Sendable, Equatable {
    public struct Entry: Sendable, Hashable {
        public var hosts: [String]
        public var keyType: String
        public var keyBase64: String

        public var fingerprint: String { HostKeyInfo.fingerprint(ofBase64Blob: keyBase64) }
    }

    public enum Verdict: Sendable, Equatable {
        case trusted
        case unknown
        /// A key is on file for this host and the server presented a different one.
        case changed(previous: [Entry])
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public init(parsing text: String) {
        var out: [Entry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix("@") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            out.append(Entry(
                hosts: fields[0].split(separator: ",").map(String.init),
                keyType: String(fields[1]),
                keyBase64: String(fields[2])
            ))
        }
        entries = out
    }

    public func serialized() -> String {
        entries.map { "\($0.hosts.joined(separator: ",")) \($0.keyType) \($0.keyBase64)\n" }.joined()
    }

    public static func pattern(address: String, port: Int) -> String {
        port == 22 ? address : "[\(address)]:\(port)"
    }

    public func entries(address: String, port: Int) -> [Entry] {
        let p = Self.pattern(address: address, port: port)
        return entries.filter { $0.hosts.contains(p) }
    }

    /// Any stored key of a different value or type counts as changed: never downgrade to "unknown".
    public func verdict(address: String, port: Int, key: HostKeyInfo) -> Verdict {
        let known = entries(address: address, port: port)
        if known.isEmpty { return .unknown }
        if known.contains(where: { $0.keyType == key.type && $0.keyBase64 == key.base64 }) { return .trusted }
        return .changed(previous: known)
    }

    public mutating func trust(address: String, port: Int, key: HostKeyInfo) {
        let p = Self.pattern(address: address, port: port)
        guard verdict(address: address, port: port, key: key) == .unknown else { return }
        entries.append(Entry(hosts: [p], keyType: key.type, keyBase64: key.base64))
    }

    public mutating func forget(address: String, port: Int) {
        let p = Self.pattern(address: address, port: port)
        entries = entries.compactMap { entry in
            var e = entry
            e.hosts.removeAll { $0 == p }
            return e.hosts.isEmpty ? nil : e
        }
    }
}
