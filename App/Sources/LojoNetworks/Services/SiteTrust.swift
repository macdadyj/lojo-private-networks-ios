import CryptoKit
import Foundation
import LojoTrust
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

    /// The fingerprint broken into lines of whole bytes, so it never wraps mid-byte.
    static func fingerprintLines(_ hex: String, perLine: Int) -> String {
        let p = pairs(hex)
        return stride(from: 0, to: p.count, by: perLine)
            .map { p[$0..<min($0 + perLine, p.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }

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
///
/// The item lives in this app's default keychain access group, which is the application
/// identifier (team prefix + bundle id, e.g. `XTL-N9H4648NB9.com.lojo.PrivateNetworks`).
/// Do not set `kSecAttrAccessGroup` to the bare bundle id: that group isn't in the
/// entitlements, so save fails with `errSecMissingEntitlement` and the pin never sticks.
enum SiteTrustStore {
    private static let legacyService = "com.lojo.PrivateNetworks.siteCA"
    private static let account = "site"

    /// Service name includes the bundle id so a shared access group can't hand this phone
    /// another app's pin. For `com.lojo.PrivateNetworks` this is the same string as before.
    private static var service: String {
        let id = Bundle.main.bundleIdentifier ?? "com.lojo.PrivateNetworks"
        return "\(id).siteCA"
    }

    static func load() -> SiteCA? {
        if let ca = load(service: service) { return ca }
        if service != legacyService { return load(service: legacyService) }
        return nil
    }

    private static func load(service: String) -> SiteCA? {
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
        for name in Set([service, legacyService]) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: name,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
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
            case -9802: return "The phone closed the TLS handshake while checking the gateway certificate."
            default: return "The TLS handshake with the gateway failed."
            }
        }
    }

    /// A certificate was rejected. Legacy HTTP must not paper over that.
    var rejectsIdentity: Bool {
        switch kind {
        case .notPaired, .pinMismatch, .pairingMismatch, .hostnameMismatch, .expired, .untrusted:
            return true
        case .handshake(let code):
            switch code {
            case -9802, -9807, -9808, -9813: return true
            default: return false
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

    static func key(host: String, port: Int) -> String {
        var name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.hasSuffix(".") { name.removeLast() }
        return "\(name.lowercased()):\(port)"
    }

    static func key(_ url: URL?) -> String {
        guard let url, let host = url.host, !host.isEmpty else { return "" }
        return key(host: host, port: GatewayAddress.port(of: url))
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
    /// A host match covers a port spelling difference between the URL and the protection space.
    func failure(_ key: String) -> TLSFailure? {
        lock.withLock {
            if let (f, at) = failures[key], Date().timeIntervalSince(at) < 30 { return f }
            let host = String(key.split(separator: ":").first ?? "")
            guard !host.isEmpty else { return nil }
            let recent = failures.filter { name, value in
                String(name.split(separator: ":").first ?? "") == host && Date().timeIntervalSince(value.1) < 5
            }
            guard recent.count == 1, let only = recent.values.first else { return nil }
            return only.0
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
        super.init()
        #if DEBUG
        assert(responds(to: NSSelectorFromString(ServerTrustChallenge.sessionSelector)),
               "URLSession will not deliver the server-trust challenge")
        assert(responds(to: NSSelectorFromString(ServerTrustChallenge.taskSelector)))
        #endif
    }

    /// The CA certificate found in the gateway's chain during pairing.
    var capturedCA: SiteCA? { lock.withLock { captured } }

    /// Session-level server trust. URLSession calls this ObjC selector; it does not call the async variant.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let result = handle(challenge, url: nil)
        completionHandler(result.0, result.1)
    }

    /// Same check when the challenge is delivered on the task instead of the session.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let result = handle(challenge, url: task.originalRequest?.url)
        completionHandler(result.0, result.1)
    }

    private func handle(_ challenge: URLAuthenticationChallenge, url: URL?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let protectionHost = challenge.protectionSpace.host
        let host = protectionHost.isEmpty ? (url?.host ?? "") : protectionHost
        let port = challenge.protectionSpace.port > 0 ? challenge.protectionSpace.port : (url.map(GatewayAddress.port(of:)) ?? GatewayAddress.defaultTLSPort)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let ders = chain.map { SecCertificateCopyData($0) as Data }
        let presentedRoot = ders.last.map(SiteCA.hex)
        var noted: [String] = [TLSObserver.key(host: host, port: port)]
        if let url { noted.append(TLSObserver.key(url)) }

        func fail(_ failure: TLSFailure) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            for key in noted { TLSObserver.shared.fail(key, failure) }
            return (.cancelAuthenticationChallenge, nil)
        }

        let anchorData: Data
        if let pairingSHA256 {
            guard let found = ders.first(where: { SiteCA.hex($0) == pairingSHA256 }) else {
                return fail(TLSFailure(kind: .pairingMismatch(presented: presentedRoot)))
            }
            anchorData = found
        } else if let stored = anchorDER {
            anchorData = stored
        } else {
            return fail(TLSFailure(kind: .notPaired))
        }
        guard let anchorCert = SecCertificateCreateWithData(nil, anchorData as CFData) else {
            return fail(TLSFailure(kind: .untrusted(code: Int(errSecDecode)), detail: "The pinned CA couldn't be read."))
        }

        let anchorHash = SiteCA.hex(anchorData)
        let extras = ders.dropFirst().filter { SiteCA.hex($0) != anchorHash }
        var nameMatched = false
        if let leaf = ders.first {
            switch GatewayChainTrust.evaluate(leafDER: leaf, intermediateDERs: Array(extras), caDER: anchorData, host: host) {
            case .trusted:
                nameMatched = true
            case .malformed:
                nameMatched = false
            case .hostnameMismatch:
                return fail(TLSFailure(kind: .hostnameMismatch, detail: "The certificate doesn't list \(host)."))
            case .pathLength:
                return fail(TLSFailure(kind: .untrusted(code: Int(errSecPathLengthConstraintExceeded)), detail: "The site CA pathlen does not allow this chain."))
            case .notServer:
                return fail(TLSFailure(kind: .untrusted(code: Int(errSecInvalidExtendedKeyUsage)), detail: "The certificate isn't a TLS server certificate."))
            case .expired:
                return fail(TLSFailure(kind: .expired))
            }
        }

        SecTrustSetNetworkFetchAllowed(trust, false)
        if let error = pinnedTrustError(trust, anchor: anchorCert, host: host, nameMatched: nameMatched) {
            let code = Int(CFErrorGetCode(error))
            let text = CFErrorCopyDescription(error) as String
            let pinnedInChain = ders.contains { SiteCA.hex($0) == anchorHash }
            let failure: TLSFailure
            switch code {
            case Int(errSecHostNameMismatch): failure = TLSFailure(kind: .hostnameMismatch, detail: text)
            case -67818, -67819: failure = TLSFailure(kind: .expired, detail: text)
            default:
                failure = pinnedInChain
                    ? TLSFailure(kind: .untrusted(code: code), detail: text)
                    : TLSFailure(kind: .pinMismatch(presented: presentedRoot), detail: text)
            }
            return fail(failure)
        }

        if pairingSHA256 != nil, let ca = SiteCA(der: anchorData) { lock.withLock { captured = ca } }
        for key in noted { TLSObserver.shared.succeed(key, leaf: ders.first.map(SiteCA.hex)) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Nil when the pinned CA verifies the chain. An IP SAN that SecTrust treats as a DNS name,
    /// and a pathlen:0 anchor with no intermediate, are accepted after the profile check agrees.
    private func pinnedTrustError(_ trust: SecTrust, anchor: SecCertificate, host: String, nameMatched: Bool) -> CFError? {
        func evaluate(policyHost: String?) -> CFError? {
            let policy = policyHost.map { SecPolicyCreateSSL(true, $0 as CFString) } ?? SecPolicyCreateSSL(true, nil)
            SecTrustSetPolicies(trust, policy)
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) { return nil }
            return error
        }

        guard var error = evaluate(policyHost: host) else { return nil }
        if nameMatched, Int(CFErrorGetCode(error)) == Int(errSecHostNameMismatch) {
            if let retry = evaluate(policyHost: nil) {
                error = retry
            } else {
                return nil
            }
        }
        // trustd applies a pathlen:0 anchor to the leaf and can report
        // errSecPathLengthConstraintExceeded even when there is no intermediate.
        // The profile check already required a direct leaf, so that result is not a longer chain.
        if nameMatched, Int(CFErrorGetCode(error)) == Int(errSecPathLengthConstraintExceeded) {
            _ = evaluate(policyHost: nil)
            if let exceptions = SecTrustCopyExceptions(trust) {
                SecTrustSetExceptions(trust, exceptions)
                var again: CFError?
                if SecTrustEvaluateWithError(trust, &again) { return nil }
                if let again { error = again }
            }
        }
        return error
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
