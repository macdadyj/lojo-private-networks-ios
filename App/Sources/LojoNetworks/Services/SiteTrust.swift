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
        let base: String
        switch kind {
        case .notPaired:
            base = "This phone hasn't been paired with your gateway, so it can't check who it's talking to. Scan the gateway's pairing code."
        case .pinMismatch(let presented):
            base = "The gateway's certificate wasn't issued by your site's certificate authority (pin mismatch\(presented.map { "; presented root \(Self.short($0))" } ?? "")). If the site CA was rotated, scan the new pairing code; otherwise something else is answering at this address."
        case .pairingMismatch(let presented):
            base = "The gateway presented a different certificate authority than the pairing code\(presented.map { " (\(Self.short($0)))" } ?? ""). Make sure you scanned the code for this gateway."
        case .hostnameMismatch:
            base = "The certificate doesn't list this address. Add it to SANS in site.env on the gateway and run gateway-tls.sh rotate."
        case .expired:
            base = "The gateway's certificate has expired or isn't valid yet (check the phone's date). Run gateway-tls.sh rotate on the gateway."
        case .untrusted:
            base = "iOS couldn't verify the gateway's certificate chain against your site CA."
        case .handshake(let code):
            switch code {
            case -9806, -9816: base = "The connection closed during the TLS handshake. The port may not be speaking HTTPS (is it the legacy HTTP port?)."
            case -9836, -9831: base = "The other end didn't answer in TLS. Usually the address points at the legacy HTTP port (8801) instead of HTTPS (8443); otherwise the server only offers an old TLS version."
            case -9802: base = "The phone closed the TLS handshake while checking the gateway certificate."
            default: base = "The TLS handshake with the gateway failed."
            }
        }
        guard let detail, !detail.isEmpty else { return base }
        return base + "\n" + detail
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

    struct PeerDecision {
        var failure: TLSFailure?
        /// SecTrust text to show if the handshake still fails after the pin was accepted.
        var report: String
        var accepted: Bool { failure == nil }
    }

    /// Pin check used by the Network.framework verify block and by URLSession.
    /// The connection is accepted only when a chain certificate's SHA-256 matches the pin,
    /// SecKey verifies the leaf under that CA, and the leaf name and dates match.
    /// SecTrust does not get a veto: an IP host or a pathlen-0 anchor can fail its policies
    /// while those checks still hold. A rejection includes the SecTrust errors.
    func evaluatePeer(trust: SecTrust, url: URL) -> PeerDecision {
        let host = url.host ?? ""
        let port = GatewayAddress.port(of: url)
        let keys = [TLSObserver.key(url), TLSObserver.key(host: host, port: port)]
        SecTrustSetNetworkFetchAllowed(trust, false)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let ders = chain.map { SecCertificateCopyData($0) as Data }
        let presented = ders.last.map(SiteCA.hex)

        let pinned: String
        if let pairingSHA256 {
            pinned = pairingSHA256
        } else if let anchorDER {
            pinned = SiteCA.hex(anchorDER)
        } else {
            let failure = TLSFailure(kind: .notPaired, detail: "No pairing fingerprint and no saved site CA.")
            for key in keys { TLSObserver.shared.fail(key, failure) }
            return PeerDecision(failure: failure, report: failure.detail ?? "")
        }

        let presentedLine = Self.presentedTrustLine(trust)
        let profile = GatewayChainTrust.explicitPin(chainDERs: ders, pinnedSHA256: pinned, host: host)
        switch profile {
        case .rejected(let rejection):
            var lines = [rejection.message, presentedLine]
            if let leaf = ders.first.flatMap(CertificateDER.parse) { lines.append(Self.leafSummary(leaf)) }
            let caDER = ders.first { SiteCA.hex($0) == pinned.lowercased() }
            let report = Self.secTrustReport(trust: trust, caDER: caDER, host: host, preamble: lines)
            let failure = failure(for: rejection, presented: presented, report: report)
            for key in keys { TLSObserver.shared.fail(key, failure) }
            return PeerDecision(failure: failure, report: report)
        case .ready(let der, let signature):
            var lines = [presentedLine]
            let signatureError = verifyLeafSignature(signature, caDER: der)
            if let signatureError {
                lines.append(signatureError)
            } else {
                lines.append("Leaf signature verified with the pinned CA key (ecdsa-with-SHA256).")
            }
            if let leaf = CertificateDER.parse(ders[0]), let ca = CertificateDER.parse(der) {
                lines.append(Self.leafSummary(leaf))
                lines.append("CA pathlen: \(ca.pathLen.map(String.init) ?? "none"). CA AKI: \(ca.hasAuthorityKeyIdentifier ? "present" : "absent"). CA SKI: \(ca.hasSubjectKeyIdentifier ? "present" : "absent").")
            }
            let report = Self.secTrustReport(trust: trust, caDER: der, host: host, preamble: lines)
            if let signatureError {
                let failure = TLSFailure(kind: .untrusted(code: Int(errSecVerifyFailed)), detail: report)
                for key in keys { TLSObserver.shared.fail(key, failure) }
                return PeerDecision(failure: failure, report: report)
            }
            if pairingSHA256 != nil, let ca = SiteCA(der: der) { lock.withLock { captured = ca } }
            if let anchor = SecCertificateCreateWithData(nil, der as CFData) {
                Self.arm(trust, anchor: anchor, host: host)
            }
            for key in keys { TLSObserver.shared.succeed(key, leaf: ders.first.map(SiteCA.hex)) }
            return PeerDecision(failure: nil, report: report)
        }
    }

    private func handle(_ challenge: URLAuthenticationChallenge, url: URL?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let protectionHost = challenge.protectionSpace.host
        let host = protectionHost.isEmpty ? (url?.host ?? "") : protectionHost
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        let port = challenge.protectionSpace.port > 0 ? challenge.protectionSpace.port : (url.map(GatewayAddress.port(of:)) ?? GatewayAddress.defaultTLSPort)
        parts.port = port
        let fallback = parts.url ?? URL(string: "https://127.0.0.1:\(port)")
        let decision = evaluatePeer(trust: trust, url: url ?? fallback ?? URL(string: "https://127.0.0.1")!)
        if decision.accepted {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    private func failure(for rejection: PinRejection, presented: String?, report: String) -> TLSFailure {
        let detail = report
        let kind: TLSFailure.Kind
        switch rejection.code {
        case .pinMismatch:
            kind = pairingSHA256 != nil ? .pairingMismatch(presented: presented) : .pinMismatch(presented: presented)
        case .hostname:
            kind = .hostnameMismatch
        case .expired:
            kind = .expired
        case .pathLength:
            kind = .untrusted(code: Int(errSecPathLengthConstraintExceeded))
        case .notServer:
            kind = .untrusted(code: Int(errSecInvalidExtendedKeyUsage))
        case .malformed:
            kind = .untrusted(code: Int(errSecDecode))
        }
        return TLSFailure(kind: kind, detail: detail)
    }

    /// Nil when the pinned CA's key signed the leaf. Anything else is a reason to refuse.
    private func verifyLeafSignature(_ signature: CertificateSignature, caDER: Data) -> String? {
        guard signature.algorithmOID == CertificateDER.ecdsaWithSHA256 else {
            return "The leaf signature algorithm is \(signature.algorithmOID), not ecdsa-with-SHA256."
        }
        guard let cert = SecCertificateCreateWithData(nil, caDER as CFData), let key = SecCertificateCopyKey(cert) else {
            return "The pinned CA public key could not be read."
        }
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            signature.signedBytes as CFData,
            signature.signature as CFData,
            &error
        )
        if ok { return nil }
        let text = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "SecKeyVerifySignature returned false"
        return "SecKeyVerifySignature (ecdsa-with-SHA256 over the TBS certificate) failed: \(text)"
    }

    private static func leafSummary(_ leaf: ParsedCertificate) -> String {
        let ips = leaf.ipAddresses.isEmpty ? "none" : leaf.ipAddresses.joined(separator: ", ")
        let dns = leaf.dnsNames.isEmpty ? "none" : leaf.dnsNames.joined(separator: ", ")
        return "Leaf notBefore \(stamp(leaf.notBefore)), notAfter \(stamp(leaf.notAfter)). IP SANs: \(ips). DNS SANs: \(dns). Leaf AKI: \(leaf.hasAuthorityKeyIdentifier ? "present" : "absent"). Leaf SKI: \(leaf.hasSubjectKeyIdentifier ? "present" : "absent")."
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The policy the TLS stack already attached, before this app replaces the anchors.
    private static func presentedTrustLine(_ trust: SecTrust) -> String {
        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        var line = ok ? "SecTrust as presented: accepted" : "SecTrust as presented: failed"
        if let error {
            line += " \(CFErrorGetDomain(error) as String) \(Int(CFErrorGetCode(error))) \(CFErrorCopyDescription(error) as String)"
        }
        if let result = SecTrustCopyResult(trust) as? [String: Any],
           let number = result[kSecTrustResultValue as String] as? NSNumber {
            line += " result \(trustResultName(number.intValue)) (\(number.intValue))"
        }
        return ([line] + propertyLines(trust)).joined(separator: "\n")
    }

    /// What SecTrust says about this chain. Recorded on every attempt so a refusal names the check.
    private static func secTrustReport(trust: SecTrust, caDER: Data?, host: String, preamble: [String]) -> String {
        var lines = preamble
        guard let caDER, let anchor = SecCertificateCreateWithData(nil, caDER as CFData) else {
            lines.append("SecTrust was not evaluated against the pinned CA because that certificate was not available.")
            return cap(lines.joined(separator: "\n"))
        }
        let sslHost = SecPolicyCreateSSL(true, host as CFString)
        let sslBare = SecPolicyCreateSSL(true, nil)
        let basic = SecPolicyCreateBasicX509()
        lines.append(probe(trust, name: "SSL(\(host))", policy: sslHost, anchor: anchor))
        lines.append(probe(trust, name: "SSL(no hostname)", policy: sslBare, anchor: anchor))
        lines.append(probe(trust, name: "BasicX509", policy: basic, anchor: anchor))
        if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            var leafTrust: SecTrust?
            if SecTrustCreateWithCertificates(leaf, sslBare, &leafTrust) == errSecSuccess, let leafTrust {
                lines.append(probe(leafTrust, name: "leaf-only SSL(no hostname)", policy: sslBare, anchor: anchor))
            }
        }
        return cap(lines.joined(separator: "\n"))
    }

    private static func probe(_ trust: SecTrust, name: String, policy: SecPolicy, anchor: SecCertificate) -> String {
        let anchorStatus = SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        let onlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, policy)
        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        var line = ok ? "\(name): accepted" : "\(name): failed"
        if anchorStatus != errSecSuccess { line += " (set anchor \(anchorStatus))" }
        if onlyStatus != errSecSuccess { line += " (anchors only \(onlyStatus))" }
        if let error {
            let code = Int(CFErrorGetCode(error))
            let domain = CFErrorGetDomain(error) as String
            let desc = CFErrorCopyDescription(error) as String
            line += " \(domain) \(code) \(desc)"
        }
        if let result = SecTrustCopyResult(trust) as? [String: Any],
           let number = result[kSecTrustResultValue as String] as? NSNumber {
            line += " result \(trustResultName(number.intValue)) (\(number.intValue))"
        }
        return ([line] + propertyLines(trust)).joined(separator: "\n")
    }

    private static func propertyLines(_ trust: SecTrust) -> [String] {
        guard let props = SecTrustCopyProperties(trust) as? [[String: Any]] else { return [] }
        var lines: [String] = []
        for (index, prop) in props.enumerated() {
            let title = prop[kSecPropertyTypeTitle as String] as? String ?? ""
            let message = prop[kSecPropertyTypeError as String] as? String ?? ""
            if !message.isEmpty { lines.append("  cert \(index) \(title): \(message)") }
        }
        return lines
    }

    /// After the explicit pin has already succeeded, make this trust object evaluate successfully
    /// so URLSession will use the credential. The verify block does not rely on this.
    private static func arm(_ trust: SecTrust, anchor: SecCertificate, host: String) {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, policy)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return }
        if let exceptions = SecTrustCopyExceptions(trust) {
            SecTrustSetExceptions(trust, exceptions)
            _ = SecTrustEvaluateWithError(trust, &error)
        }
    }

    private static func trustResultName(_ value: Int) -> String {
        switch value {
        case 1: return "proceed"
        case 2: return "confirm"
        case 3: return "deny"
        case 4: return "unspecified"
        case 5: return "recoverableTrustFailure"
        case 6: return "fatalTrustFailure"
        case 7: return "otherError"
        default: return "invalid"
        }
    }

    private static func cap(_ text: String) -> String {
        if text.count <= 1800 { return text }
        return String(text.prefix(1800)) + "…"
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
