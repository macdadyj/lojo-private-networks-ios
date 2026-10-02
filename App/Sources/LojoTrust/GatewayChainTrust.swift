import Foundation

/// Selector URLSession actually invokes for a server-trust challenge on a session delegate.
/// The async Swift method `urlSession(_:didReceive:) async` is a different entry point and is not
/// called, so implementing only that leaves iOS on default trust (private CA rejected, fatal alert).
public enum ServerTrustChallenge {
    public static let sessionSelector = "URLSession:didReceiveChallenge:completionHandler:"
    public static let taskSelector = "URLSession:task:didReceiveChallenge:completionHandler:"
}

/// Fields the phone checks itself on a gateway certificate. The cryptographic signature is
/// checked with SecKey on the phone; this covers name, dates, and path length.
public struct ParsedCertificate: Equatable, Sendable {
    public var notBefore: Date
    public var notAfter: Date
    public var signatureOID: String
    public var isCA: Bool
    public var pathLen: Int?
    public var basicConstraintsCritical: Bool
    public var dnsNames: [String]
    public var ipAddresses: [String]
    public var extendedKeyUsageOIDs: [String]
    public var hasAuthorityKeyIdentifier: Bool
    public var hasSubjectKeyIdentifier: Bool

    public var hasServerAuth: Bool {
        extendedKeyUsageOIDs.contains(CertificateDER.serverAuthOID)
    }

    public init(
        notBefore: Date,
        notAfter: Date,
        signatureOID: String,
        isCA: Bool,
        pathLen: Int?,
        basicConstraintsCritical: Bool,
        dnsNames: [String],
        ipAddresses: [String],
        extendedKeyUsageOIDs: [String],
        hasAuthorityKeyIdentifier: Bool = false,
        hasSubjectKeyIdentifier: Bool = false
    ) {
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.signatureOID = signatureOID
        self.isCA = isCA
        self.pathLen = pathLen
        self.basicConstraintsCritical = basicConstraintsCritical
        self.dnsNames = dnsNames
        self.ipAddresses = ipAddresses
        self.extendedKeyUsageOIDs = extendedKeyUsageOIDs
        self.hasAuthorityKeyIdentifier = hasAuthorityKeyIdentifier
        self.hasSubjectKeyIdentifier = hasSubjectKeyIdentifier
    }
}

/// The bytes SecKeyVerifySignature needs: the DER tbsCertificate and the ECDSA signature value.
public struct CertificateSignature: Equatable, Sendable {
    public var algorithmOID: String
    /// DER encoding of tbsCertificate, which is the message that was signed.
    public var signedBytes: Data
    /// Contents of the signature BIT STRING (DER SEQUENCE of r and s), without the unused-bits byte.
    public var signature: Data
}

/// A chain is ready for SecKey verification, or it was rejected before that.
public enum ExplicitPin: Equatable, Sendable {
    case ready(caDER: Data, signature: CertificateSignature)
    case rejected(PinRejection)
}

public struct PinRejection: Equatable, Sendable {
    public enum Code: Equatable, Sendable {
        case pinMismatch
        case hostname
        case expired
        case pathLength
        case notServer
        case malformed
    }

    public var code: Code
    public var message: String
}

public enum CertificateDER {
    public static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    public static let serverAuthOID = "1.3.6.1.5.5.7.3.1"
    private static let subjectAltName = "2.5.29.17"
    private static let basicConstraints = "2.5.29.19"
    private static let extKeyUsage = "2.5.29.37"
    private static let authorityKeyIdentifier = "2.5.29.35"
    private static let subjectKeyIdentifier = "2.5.29.14"

    public static func parse(_ der: Data) -> ParsedCertificate? {
        var reader = DERReader(der)
        guard let cert = reader.readTLV(), cert.tag == 0x30 else { return nil }
        var outer = DERReader(cert.body)
        guard let tbsTLV = outer.readTLV(), tbsTLV.tag == 0x30 else { return nil }
        var tbs = DERReader(tbsTLV.body)
        if tbs.peekTag() == 0xA0 { guard tbs.readTLV() != nil else { return nil } }
        guard tbs.readTLV() != nil else { return nil }
        guard let signature = tbs.readTLV(), signature.tag == 0x30, let signatureOID = oid(in: signature.body) else { return nil }
        guard tbs.readTLV() != nil, let validity = tbs.readTLV(), validity.tag == 0x30 else { return nil }
        guard let dates = parseValidity(validity.body) else { return nil }
        guard tbs.readTLV() != nil, tbs.readTLV() != nil else { return nil }

        var dns: [String] = []
        var ips: [String] = []
        var ekus: [String] = []
        var isCA = false
        var pathLen: Int?
        var bcCritical = false
        var sawBC = false
        var hasAKI = false
        var hasSKI = false

        while let field = tbs.readTLV() {
            guard field.tag == 0xA3 else { continue }
            guard let extensions = parseExtensions(field.body) else { return nil }
            for ext in extensions {
                switch ext.oid {
                case subjectAltName:
                    guard let names = parseSAN(ext.value) else { return nil }
                    dns = names.dns
                    ips = names.ips
                case basicConstraints:
                    guard let bc = parseBasicConstraints(ext.value) else { return nil }
                    sawBC = true
                    bcCritical = ext.critical
                    isCA = bc.isCA
                    pathLen = bc.pathLen
                case extKeyUsage:
                    guard let ids = parseEKU(ext.value) else { return nil }
                    ekus = ids
                case authorityKeyIdentifier:
                    hasAKI = true
                case subjectKeyIdentifier:
                    hasSKI = true
                default:
                    break
                }
            }
        }
        if !sawBC { isCA = false }
        return ParsedCertificate(
            notBefore: dates.0,
            notAfter: dates.1,
            signatureOID: signatureOID,
            isCA: isCA,
            pathLen: pathLen,
            basicConstraintsCritical: bcCritical,
            dnsNames: dns,
            ipAddresses: ips,
            extendedKeyUsageOIDs: ekus,
            hasAuthorityKeyIdentifier: hasAKI,
            hasSubjectKeyIdentifier: hasSKI
        )
    }

    /// IP hosts are matched only against iPAddress SANs. `SecPolicyCreateSSL(true, ip)` can still
    /// treat that literal as a DNS name and return a hostname mismatch.
    public static func isIPHost(_ host: String) -> Bool {
        canonicalIPv4(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) != nil
    }

    public static func signatureMaterial(_ der: Data) -> CertificateSignature? {
        var reader = DERReader(der)
        guard let cert = reader.readRawTLV(), cert.tag == 0x30 else { return nil }
        var outer = DERReader(cert.body)
        guard let tbs = outer.readRawTLV(), tbs.tag == 0x30 else { return nil }
        guard let algorithm = outer.readRawTLV(), algorithm.tag == 0x30, let oid = oid(in: algorithm.body) else { return nil }
        guard let bits = outer.readRawTLV(), bits.tag == 0x03, let payload = bitStringPayload(bits.body) else { return nil }
        return CertificateSignature(algorithmOID: oid, signedBytes: tbs.full, signature: payload)
    }

    /// IP hosts are matched only against iPAddress SANs. A dotted address is not a DNS name,
    /// which is why `SecPolicyCreateSSL` can report a hostname mismatch for a cert that is valid
    /// for that IP.
    public static func hostMatches(_ host: String, dnsNames: [String], ipAddresses: [String]) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespacesAndNewlines)
        if let ip = canonicalIPv4(trimmed) {
            return ipAddresses.contains(ip)
        }
        let bare = stripTrailingDot(trimmed.lowercased())
        guard !bare.isEmpty, !bare.contains(":") else { return false }
        return dnsNames.contains { stripTrailingDot($0.lowercased()) == bare }
    }

    private static func parseValidity(_ body: Data) -> (Date, Date)? {
        var reader = DERReader(body)
        guard let notBefore = reader.readTLV(), let notAfter = reader.readTLV() else { return nil }
        guard notBefore.tag == 0x17 || notBefore.tag == 0x18, notAfter.tag == 0x17 || notAfter.tag == 0x18 else { return nil }
        guard let start = parseTime(notBefore.body), let end = parseTime(notAfter.body) else { return nil }
        return (start, end)
    }

    private static func parseTime(_ body: Data) -> Date? {
        guard let raw = String(data: body, encoding: .ascii), raw.hasSuffix("Z") else { return nil }
        let digits = String(raw.dropLast())
        let year: Int
        let rest: String
        if digits.count == 12, let yy = Int(digits.prefix(2)) {
            year = yy >= 50 ? 1900 + yy : 2000 + yy
            rest = String(digits.dropFirst(2))
        } else if digits.count == 14, let yyyy = Int(digits.prefix(4)) {
            year = yyyy
            rest = String(digits.dropFirst(4))
        } else {
            return nil
        }
        guard rest.count == 10,
              let month = Int(rest.prefix(2)),
              let day = Int(rest.dropFirst(2).prefix(2)),
              let hour = Int(rest.dropFirst(4).prefix(2)),
              let minute = Int(rest.dropFirst(6).prefix(2)),
              let second = Int(rest.dropFirst(8).prefix(2))
        else { return nil }
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return parts.date
    }

    private struct Extension {
        var oid: String
        var critical: Bool
        var value: Data
    }

    private static func parseExtensions(_ explicitBody: Data) -> [Extension]? {
        var wrapped = DERReader(explicitBody)
        guard let sequence = wrapped.readTLV(), sequence.tag == 0x30 else { return nil }
        var reader = DERReader(sequence.body)
        var out: [Extension] = []
        while reader.remaining > 0 {
            guard let ext = reader.readTLV(), ext.tag == 0x30 else { return nil }
            var fields = DERReader(ext.body)
            guard let oidTLV = fields.readTLV(), oidTLV.tag == 0x06, let oid = oidString(oidTLV.body) else { return nil }
            var critical = false
            if fields.peekTag() == 0x01 {
                guard let flag = fields.readTLV(), flag.body.count == 1 else { return nil }
                critical = flag.body[0] != 0
            }
            guard let value = fields.readTLV(), value.tag == 0x04 else { return nil }
            out.append(Extension(oid: oid, critical: critical, value: value.body))
        }
        return out
    }

    private static func parseSAN(_ body: Data) -> (dns: [String], ips: [String])? {
        var reader = DERReader(body)
        guard let sequence = reader.readTLV(), sequence.tag == 0x30 else { return nil }
        var names = DERReader(sequence.body)
        var dns: [String] = []
        var ips: [String] = []
        while names.remaining > 0 {
            guard let name = names.readTLV() else { return nil }
            switch name.tag {
            case 0x82:
                guard let text = String(data: name.body, encoding: .ascii) else { return nil }
                dns.append(text)
            case 0x87:
                if name.body.count == 4 {
                    ips.append(name.body.map { String(Int($0)) }.joined(separator: "."))
                }
            default:
                break
            }
        }
        return (dns, ips)
    }

    private static func parseBasicConstraints(_ body: Data) -> (isCA: Bool, pathLen: Int?)? {
        var reader = DERReader(body)
        guard let sequence = reader.readTLV(), sequence.tag == 0x30 else { return nil }
        var fields = DERReader(sequence.body)
        var isCA = false
        var pathLen: Int?
        while fields.remaining > 0 {
            guard let field = fields.readTLV() else { return nil }
            if field.tag == 0x01, field.body.count == 1 {
                isCA = field.body[0] != 0
            } else if field.tag == 0x02 {
                guard let value = integer(field.body), value >= 0 else { return nil }
                pathLen = value
            }
        }
        return (isCA, pathLen)
    }

    private static func parseEKU(_ body: Data) -> [String]? {
        var reader = DERReader(body)
        guard let sequence = reader.readTLV(), sequence.tag == 0x30 else { return nil }
        var fields = DERReader(sequence.body)
        var oids: [String] = []
        while fields.remaining > 0 {
            guard let field = fields.readTLV(), field.tag == 0x06, let text = oidString(field.body) else { return nil }
            oids.append(text)
        }
        return oids
    }

    private static func bitStringPayload(_ body: Data) -> Data? {
        guard let unused = body.first, unused == 0, body.count > 1 else { return nil }
        return body.dropFirst()
    }

    private static func oid(in algorithm: Data) -> String? {
        var reader = DERReader(algorithm)
        guard let field = reader.readTLV(), field.tag == 0x06 else { return nil }
        return oidString(field.body)
    }

    private static func oidString(_ body: Data) -> String? {
        guard let first = body.first else { return nil }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        var finished = body.count == 1
        for byte in body.dropFirst() {
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
                finished = true
            } else {
                finished = false
            }
        }
        guard finished else { return nil }
        return parts.map(String.init).joined(separator: ".")
    }

    private static func integer(_ body: Data) -> Int? {
        guard !body.isEmpty, body.count <= 4 else { return nil }
        var value = 0
        for byte in body { value = (value << 8) | Int(byte) }
        if body[0] & 0x80 != 0 { return nil }
        return value
    }

    private static func canonicalIPv4(_ host: String) -> String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var numbers: [String] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), (0...255).contains(number)
            else { return nil }
            if part.count > 1, part.first == "0" { return nil }
            numbers.append(String(number))
        }
        return numbers.joined(separator: ".")
    }

    private static func stripTrailingDot(_ host: String) -> String {
        host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}

/// Whether a leaf signed by the pinned CA may be trusted for `host`.
/// A CA with `pathlen:0` may sign this leaf directly. It may not sign another CA in between.
public enum GatewayChainTrust {
    public enum Verdict: Equatable, Sendable {
        case trusted
        case hostnameMismatch
        case pathLength
        case notServer
        case expired
        case malformed
    }

    public static func evaluate(
        leafDER: Data,
        intermediateDERs: [Data] = [],
        caDER: Data,
        host: String,
        now: Date = Date()
    ) -> Verdict {
        guard let leaf = CertificateDER.parse(leafDER), let ca = CertificateDER.parse(caDER), ca.isCA else {
            return .malformed
        }
        var intermediates = 0
        for der in intermediateDERs where der != caDER {
            guard let parsed = CertificateDER.parse(der) else { return .malformed }
            if parsed.isCA { intermediates += 1 }
        }
        if let limit = ca.pathLen, intermediates > limit { return .pathLength }
        if leaf.isCA { return .notServer }
        if !leaf.extendedKeyUsageOIDs.isEmpty, !leaf.hasServerAuth { return .notServer }
        if now < leaf.notBefore || now > leaf.notAfter { return .expired }
        if !CertificateDER.hostMatches(host, dnsNames: leaf.dnsNames, ipAddresses: leaf.ipAddresses) {
            return .hostnameMismatch
        }
        return .trusted
    }

    /// Accept a chain only when it contains the pinned CA and the leaf's name, dates, and path
    /// length are valid. The caller still has to verify `signature` with that CA's key.
    public static func explicitPin(chainDERs: [Data], pinnedSHA256: String, host: String, now: Date = Date()) -> ExplicitPin {
        let pinned = pinnedSHA256.lowercased()
        guard pinned.count == 64, pinned.allSatisfy(\.isHexDigit) else {
            return .rejected(PinRejection(code: .malformed, message: "The pinned CA fingerprint is not 64 hex characters."))
        }
        guard let leafDER = chainDERs.first else {
            return .rejected(PinRejection(code: .malformed, message: "The server sent no certificate."))
        }
        let presented = chainDERs.map { DigestSHA256.hex($0) }
        guard let caIndex = presented.firstIndex(of: pinned) else {
            let list = presented.isEmpty ? "none" : presented.joined(separator: ", ")
            return .rejected(PinRejection(
                code: .pinMismatch,
                message: "No certificate in the server chain has SHA-256 \(pinned). Presented: \(list)."
            ))
        }
        let caDER = chainDERs[caIndex]
        guard let leaf = CertificateDER.parse(leafDER) else {
            return .rejected(PinRejection(code: .malformed, message: "The leaf certificate could not be parsed."))
        }
        guard let ca = CertificateDER.parse(caDER) else {
            return .rejected(PinRejection(code: .malformed, message: "The pinned certificate could not be parsed."))
        }
        let intermediates = chainDERs.enumerated().compactMap { index, der -> Data? in
            guard index != 0, index != caIndex else { return nil }
            return der
        }
        let verdict = evaluate(leafDER: leafDER, intermediateDERs: intermediates, caDER: caDER, host: host, now: now)
        if let rejection = rejection(verdict, host: host, leaf: leaf, ca: ca, now: now) {
            return .rejected(rejection)
        }
        guard let signature = CertificateDER.signatureMaterial(leafDER) else {
            return .rejected(PinRejection(code: .malformed, message: "The leaf signature could not be read."))
        }
        guard signature.algorithmOID == CertificateDER.ecdsaWithSHA256 else {
            return .rejected(PinRejection(
                code: .malformed,
                message: "The leaf is signed with \(signature.algorithmOID), not ecdsa-with-SHA256 (\(CertificateDER.ecdsaWithSHA256))."
            ))
        }
        return .ready(caDER: caDER, signature: signature)
    }

    private static func rejection(_ verdict: Verdict, host: String, leaf: ParsedCertificate, ca: ParsedCertificate, now: Date) -> PinRejection? {
        switch verdict {
        case .trusted:
            return nil
        case .hostnameMismatch:
            let ips = leaf.ipAddresses.isEmpty ? "none" : leaf.ipAddresses.joined(separator: ", ")
            let dns = leaf.dnsNames.isEmpty ? "none" : leaf.dnsNames.joined(separator: ", ")
            return PinRejection(
                code: .hostname,
                message: "The leaf SAN does not include \(host). IP SANs: \(ips). DNS SANs: \(dns). An IP host is matched only against iPAddress SANs."
            )
        case .expired:
            return PinRejection(
                code: .expired,
                message: "The leaf is outside its validity window at \(stamp(now)). notBefore \(stamp(leaf.notBefore)), notAfter \(stamp(leaf.notAfter))."
            )
        case .pathLength:
            let limit = ca.pathLen.map(String.init) ?? "none"
            return PinRejection(
                code: .pathLength,
                message: "The pinned CA has pathlen \(limit) and the chain includes an intermediate CA. pathlen 0 allows the leaf directly under that CA, not another CA in between."
            )
        case .notServer:
            let eku = leaf.extendedKeyUsageOIDs.isEmpty ? "none" : leaf.extendedKeyUsageOIDs.joined(separator: ", ")
            return PinRejection(
                code: .notServer,
                message: "The leaf is not a TLS server certificate (CA: \(leaf.isCA), EKU: \(eku))."
            )
        case .malformed:
            return PinRejection(
                code: .malformed,
                message: "The pinned certificate is not a CA (CA: \(ca.isCA)), or the chain could not be parsed."
            )
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct DERReader {
    let data: Data
    var index = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - index }

    func peekTag() -> UInt8? {
        index < data.count ? data[index] : nil
    }

    mutating func readTLV() -> (tag: UInt8, body: Data)? {
        guard index < data.count else { return nil }
        let tag = data[index]
        index += 1
        guard let length = readLength(), index + length <= data.count else { return nil }
        let body = data.subdata(in: index..<(index + length))
        index += length
        return (tag, body)
    }

    mutating func readRawTLV() -> (tag: UInt8, body: Data, full: Data)? {
        let start = index
        guard let tlv = readTLV() else { return nil }
        return (tlv.tag, tlv.body, data.subdata(in: start..<index))
    }

    private mutating func readLength() -> Int? {
        guard index < data.count else { return nil }
        let first = Int(data[index])
        index += 1
        if first < 0x80 { return first }
        let count = first & 0x7F
        guard count > 0, count <= 4, index + count <= data.count else { return nil }
        var value = 0
        for _ in 0..<count {
            value = (value << 8) | Int(data[index])
            index += 1
        }
        return value
    }
}
