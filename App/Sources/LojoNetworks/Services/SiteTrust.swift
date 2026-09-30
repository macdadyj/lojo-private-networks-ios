import CryptoKit
import Foundation
import Security

/// The site's private certificate authority, pinned on this phone after pairing.
struct SiteCA: Sendable, Equatable {
    let der: Data
    let sha256: String

    init?(der: Data) {
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else { return nil }
        self.der = der
        sha256 = SiteCA.hex(der)
    }

    var certificate: SecCertificate { SecCertificateCreateWithData(nil, der as CFData)! }

    var subject: String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Site CA"
    }

    /// "94:8A:27:44 … 97:FE:BA" — enough to compare with `gateway-tls.sh status` at a glance.
    var shortFingerprint: String {
        let pairs = SiteCA.pairs(sha256)
        return pairs.prefix(4).joined(separator: ":") + " … " + pairs.suffix(3).joined(separator: ":")
    }

    var fullFingerprint: String { SiteCA.pairs(sha256).joined(separator: ":") }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func pairs(_ hex: String) -> [String] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2)]).uppercased()
        }
    }
}

/// Keychain storage for the pinned site CA (this device only, available after first unlock).
enum SiteTrustStore {
    private static let service = "com.lojo.PrivateNetworks.siteCA"
    private static let account = "site"

    static func load() -> SiteCA? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return SiteCA(der: data)
    }

    static func save(_ ca: SiteCA) throws {
        delete()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: ca.der,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// What the gateway's pairing QR code carries: lojo://pair?v=1&n=&lan=&ov=&ca=<sha256 hex>.
struct PairingOffer: Sendable, Hashable, Identifiable {
    let name: String
    let lan: URL?
    let overlay: URL?
    let caSHA256: String

    var id: String { caSHA256 }
    var fingerprint: String { SiteCA.pairs(caSHA256).joined(separator: ":") }

    init?(code raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text), comps.scheme?.lowercased() == "lojo",
              comps.host?.lowercased() == "pair" else { return nil }
        var q: [String: String] = [:]
        // URLSearchParams (the gateway's encoder) writes spaces as "+", which URLComponents keeps.
        for item in comps.queryItems ?? [] { q[item.name] = item.value?.replacingOccurrences(of: "+", with: " ") }
        guard q["v"] == "1", let ca = q["ca"]?.lowercased(), ca.count == 64,
              ca.allSatisfy({ $0.isHexDigit }) else { return nil }
        func https(_ s: String?) -> URL? {
            guard let s, let url = GatewayAddress.normalize(s), url.scheme == "https" else { return nil }
            return url
        }
        lan = https(q["lan"])
        overlay = https(q["ov"])
        guard lan != nil || overlay != nil else { return nil }
        name = (q["n"]?.isEmpty == false ? q["n"] : nil) ?? "My Private Network"
        caSHA256 = ca
    }
}

/// Why a TLS connection to the gateway was refused, in words an owner and support can act on.
struct TLSFailure: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case notPaired
        case pinMismatch(presented: String?)
        case pairingMismatch(presented: String?)
        case hostnameMismatch
        case expired
        case untrusted(code: Int)
        case handshake(code: Int)
    }

    let kind: Kind
    var detail: String? = nil

    var technical: String {
        switch kind {
        case .notPaired: return "TLS: no pinned site CA"
        case .pinMismatch: return "TLS pin mismatch"
        case .pairingMismatch: return "TLS pairing fingerprint mismatch"
        case .hostnameMismatch: return "TLS errSecHostNameMismatch (-67602)"
        case .expired: return "TLS errSecCertificateExpired (-67818)"
        case .untrusted(let code): return "TLS trust failed (\(code))"
        case .handshake(let code): return "TLS \(Self.sslName(code)) (\(code))"
        }
    }

    var meaning: String {
        switch kind {
        case .notPaired:
            return "This phone hasn't been paired with your gateway, so it can't check who it's talking to. Scan the gateway's pairing code."
        case .pinMismatch(let presented):
            return "The gateway's certificate wasn't issued by your site's certificate authority (pin mismatch\(presented.map { "; presented root \(Self.short($0))" } ?? "")). If the site CA was rotated, scan the new pairing code; otherwise something else is answering at this address."
        case .pairingMismatch(let presented):
            return "The gateway presented a different certificate authority than the pairing code\(presented.map { " (\(Self.short($0)))" } ?? ""). Make sure you scanned the code for this gateway."
        case .hostnameMismatch:
            return "The certificate doesn't list this address. Add it to SANS in site.env on the gateway and run gateway-tls.sh rotate."
        case .expired:
            return "The gateway's certificate has expired or isn't valid yet (check the phone's date). Run gateway-tls.sh rotate on the gateway."
        case .untrusted:
            return "iOS couldn't verify the gateway's certificate chain against your site CA\(detail.map { ": \($0)" } ?? ".")"
        case .handshake(let code):
            switch code {
            case -9806, -9816: return "The connection closed during the TLS handshake. The port may not be speaking HTTPS (is it the legacy HTTP port?)."
            case -9836, -9831: return "The other end didn't answer in TLS. Usually the address points at the legacy HTTP port (8801) instead of HTTPS (8443); otherwise the server only offers an old TLS version."
            default: return "The TLS handshake with the gateway failed."
            }
        }
    }

    static func sslName(_ code: Int) -> String {
        switch code {
        case -9806: return "errSSLClosedAbort"
        case -9816: return "errSSLClosedNoNotify"
        case -9807: return "errSSLXCertChainInvalid"
        case -9808: return "errSSLBadCert"
        case -9813: return "errSSLNoRootCert"
        case -9814: return "errSSLCertExpired"
        case -9824: return "errSSLPeerHandshakeFail"
        case -9831, -9836: return "errSSLPeerProtocolVersion"
        case -9802: return "errSSLFatalAlert"
        default: return "SSL error"
        }
    }

    private static func short(_ hex: String) -> String {
        let p = SiteCA.pairs(hex)
        return p.prefix(4).joined(separator: ":") + "…"
    }
}

/// What the phone learned about the last TLS session to each host:port.
struct TLSSession: Sendable, Hashable {
    var version: String?
    var leafSHA256: String?
}

/// Thread-safe notes from the URLSession delegate, read back when a request fails or succeeds.
final class TLSObserver: @unchecked Sendable {
    static let shared = TLSObserver()
    private let lock = NSLock()
    private var failures: [String: (TLSFailure, Date)] = [:]
    private var sessions: [String: TLSSession] = [:]

    static func key(_ url: URL?) -> String {
        guard let url, let host = url.host else { return "" }
        return "\(host):\(GatewayAddress.port(of: url))"
    }

    func fail(_ key: String, _ f: TLSFailure) { lock.withLock { failures[key] = (f, Date()) } }
    func succeed(_ key: String, leaf: String?) {
        lock.withLock {
            failures[key] = nil
            sessions[key, default: TLSSession()].leafSHA256 = leaf
        }
    }
    func version(_ key: String, _ v: String?) { lock.withLock { sessions[key, default: TLSSession()].version = v } }
    /// The failure recorded by the delegate for the request that just failed (ignores stale notes).
    func failure(_ key: String) -> TLSFailure? {
        lock.withLock {
            guard let (f, at) = failures[key], Date().timeIntervalSince(at) < 30 else { return nil }
            return f
        }
    }
    func session(_ key: String) -> TLSSession? { lock.withLock { sessions[key] } }
}

/// Trusts exactly one CA: the pinned site CA (or, while pairing, the CA whose SHA-256 the QR code
/// carries). The system trust store is never consulted, so a public or rogue CA can't stand in.
final class PinningDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let anchorDER: Data?
    private let pairingSHA256: String?
    private let lock = NSLock()
    private var captured: SiteCA?

    init(anchor: SiteCA?, pairingSHA256: String? = nil) {
        anchorDER = anchor?.der
        self.pairingSHA256 = pairingSHA256
    }

    /// The CA certificate found in the gateway's chain during pairing.
    var capturedCA: SiteCA? { lock.withLock { captured } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let host = challenge.protectionSpace.host
        let key = "\(host):\(challenge.protectionSpace.port)"
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let ders = chain.map { SecCertificateCopyData($0) as Data }
        let presentedRoot = ders.last.map(SiteCA.hex)

        var anchor: Data?
        if let pairingSHA256 {
            anchor = ders.first { SiteCA.hex($0) == pairingSHA256 }
            if anchor == nil {
                TLSObserver.shared.fail(key, TLSFailure(kind: .pairingMismatch(presented: presentedRoot)))
                return (.cancelAuthenticationChallenge, nil)
            }
        } else {
            anchor = anchorDER
            guard anchor != nil else {
                TLSObserver.shared.fail(key, TLSFailure(kind: .notPaired))
                return (.cancelAuthenticationChallenge, nil)
            }
        }
        guard let anchorDER = anchor, let anchorCert = SecCertificateCreateWithData(nil, anchorDER as CFData) else {
            return (.cancelAuthenticationChallenge, nil)
        }

        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [anchorCert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            if pairingSHA256 != nil, let ca = SiteCA(der: anchorDER) { lock.withLock { captured = ca } }
            TLSObserver.shared.succeed(key, leaf: ders.first.map(SiteCA.hex))
            return (.useCredential, URLCredential(trust: trust))
        }

        let code = error.map { CFErrorGetCode($0) } ?? 0
        let text = error.map { CFErrorCopyDescription($0) as String }
        let pinnedInChain = ders.contains(anchorDER)
        let failure: TLSFailure
        switch Int(code) {
        case -67602: failure = TLSFailure(kind: .hostnameMismatch, detail: text)
        case -67818, -67819: failure = TLSFailure(kind: .expired, detail: text)
        default:
            failure = pinnedInChain
                ? TLSFailure(kind: .untrusted(code: Int(code)), detail: text)
                : TLSFailure(kind: .pinMismatch(presented: presentedRoot), detail: text)
        }
        TLSObserver.shared.fail(key, failure)
        return (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last, let url = task.originalRequest?.url, url.scheme == "https" else { return }
        let v: String?
        switch t.negotiatedTLSProtocolVersion {
        case .TLSv13?: v = "TLS 1.3"
        case .TLSv12?: v = "TLS 1.2"
        case nil: v = nil
        default: v = "TLS (older)"
        }
        TLSObserver.shared.version(TLSObserver.key(url), v)
    }
}
