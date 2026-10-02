import XCTest
@testable import LojoTrust

/// The gateway profile from the phone failure: ECDSA P-256 leaf, ecdsa-with-SHA256, CA:FALSE,
/// serverAuth, iPAddress SANs (not DNS) for the LAN and overlay, 397 days (30 Sep 2026–1 Nov 2027),
/// signed by an ECDSA P-256 CA with CA:TRUE, pathlen:0.
final class GatewayChainTrustTests: XCTestCase {
    private var fixture: GatewayCertFixture!

    override func setUpWithError() throws {
        fixture = try GatewayCertFixture()
    }

    override func tearDown() {
        if let fixture {
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixture = nil
    }

    func testGeneratedLeafMatchesTheGatewayProfile() throws {
        let leaf = try XCTUnwrap(CertificateDER.parse(fixture.leaf))
        let ca = try XCTUnwrap(CertificateDER.parse(fixture.ca))

        XCTAssertEqual(leaf.signatureOID, CertificateDER.ecdsaWithSHA256)
        XCTAssertEqual(ca.signatureOID, CertificateDER.ecdsaWithSHA256)
        XCTAssertFalse(leaf.isCA)
        XCTAssertTrue(leaf.basicConstraintsCritical)
        XCTAssertNil(leaf.pathLen)
        XCTAssertTrue(leaf.hasServerAuth)
        XCTAssertEqual(leaf.ipAddresses, ["192.168.7.103", "100.96.1.18", "127.0.0.1"])
        XCTAssertEqual(leaf.dnsNames, ["santacomputa", "santacomputa.local", "localhost"])
        XCTAssertFalse(leaf.dnsNames.contains("100.96.1.18"))
        XCTAssertTrue(ca.isCA)
        XCTAssertTrue(ca.basicConstraintsCritical)
        XCTAssertEqual(ca.pathLen, 0)
        XCTAssertEqual(leaf.notAfter.timeIntervalSince(leaf.notBefore), 397 * 86_400, accuracy: 1)
        try fixture.assertOpenSSLVerifiesLeaf()
    }

    func testOverlayAndLANAddressesAreTrustedUnderPathLenZero() throws {
        let now = try insideValidity()
        for host in ["100.96.1.18", "192.168.7.103", "127.0.0.1", "santacomputa", "SantaComputa.local", "localhost"] {
            XCTAssertEqual(
                GatewayChainTrust.evaluate(leafDER: fixture.leaf, caDER: fixture.ca, host: host, now: now),
                .trusted,
                host
            )
        }
    }

    func testIPAddressIsNotAcceptedAsADNSName() throws {
        let leaf = try XCTUnwrap(CertificateDER.parse(fixture.leaf))
        XCTAssertFalse(CertificateDER.hostMatches("100.96.1.18", dnsNames: leaf.dnsNames, ipAddresses: []))
        XCTAssertTrue(CertificateDER.hostMatches("100.96.1.18", dnsNames: [], ipAddresses: leaf.ipAddresses))
        let now = try insideValidity()
        XCTAssertEqual(
            GatewayChainTrust.evaluate(leafDER: fixture.leaf, caDER: fixture.ca, host: "100.96.1.19", now: now),
            .hostnameMismatch
        )
        XCTAssertEqual(
            GatewayChainTrust.evaluate(leafDER: fixture.leaf, caDER: fixture.ca, host: "other.example", now: now),
            .hostnameMismatch
        )
    }

    func testPathLenZeroRejectsAnIntermediateCA() throws {
        let now = try insideValidity()
        XCTAssertEqual(
            GatewayChainTrust.evaluate(
                leafDER: fixture.leaf,
                intermediateDERs: [fixture.otherCA],
                caDER: fixture.ca,
                host: "100.96.1.18",
                now: now
            ),
            .pathLength
        )
    }

    func testDirectLeafIsNotAPathLengthViolation() throws {
        let now = try insideValidity()
        XCTAssertEqual(
            GatewayChainTrust.evaluate(
                leafDER: fixture.leaf,
                intermediateDERs: [fixture.ca],
                caDER: fixture.ca,
                host: "100.96.1.18",
                now: now
            ),
            .trusted
        )
    }

    func testOutsideValidityIsExpired() throws {
        let leaf = try XCTUnwrap(CertificateDER.parse(fixture.leaf))
        XCTAssertEqual(
            GatewayChainTrust.evaluate(leafDER: fixture.leaf, caDER: fixture.ca, host: "100.96.1.18", now: leaf.notBefore.addingTimeInterval(-1)),
            .expired
        )
        XCTAssertEqual(
            GatewayChainTrust.evaluate(leafDER: fixture.leaf, caDER: fixture.ca, host: "100.96.1.18", now: leaf.notAfter.addingTimeInterval(1)),
            .expired
        )
    }

    func testURLSessionChallengeSelectorIsTheCompletionHandler() {
        XCTAssertEqual(ServerTrustChallenge.sessionSelector, "URLSession:didReceiveChallenge:completionHandler:")
        XCTAssertEqual(ServerTrustChallenge.taskSelector, "URLSession:task:didReceiveChallenge:completionHandler:")
        XCTAssertFalse(ServerTrustChallenge.sessionSelector.contains("async"))
    }

    private func insideValidity() throws -> Date {
        let leaf = try XCTUnwrap(CertificateDER.parse(fixture.leaf))
        return leaf.notBefore.addingTimeInterval(3_600)
    }
}

private struct GatewayCertFixture {
    let directory: URL
    let ca: Data
    let leaf: Data
    let otherCA: Data

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lojo-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("demoCA"), withIntermediateDirectories: true)
        self.directory = directory
        let ca = directory.appendingPathComponent("ca.crt")
        let leaf = directory.appendingPathComponent("leaf.crt")
        let other = directory.appendingPathComponent("other-ca.crt")
        try Self.write(Self.caConfig, to: directory.appendingPathComponent("ca.cnf"))
        try Data().write(to: directory.appendingPathComponent("demoCA/index.txt"))
        try Self.write("01\n", to: directory.appendingPathComponent("demoCA/serial"))

        try Self.openssl(directory, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"])
        try Self.openssl(directory, ["req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "3650", "-config", "ca.cnf", "-extensions", "v3_ca", "-out", "ca.crt"])
        try Self.openssl(directory, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"])
        try Self.openssl(directory, ["req", "-new", "-key", "leaf.key", "-subj", "/O=LOJO Private Networks/CN=LOJO VPN gateway", "-out", "leaf.csr"])
        try Self.openssl(directory, ["ca", "-config", "ca.cnf", "-in", "leaf.csr", "-out", "leaf.crt", "-batch", "-notext", "-startdate", "260930000000Z", "-enddate", "271101000000Z"])
        try Self.openssl(directory, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "other.key"])
        try Self.openssl(directory, ["req", "-x509", "-new", "-key", "other.key", "-sha256", "-days", "3650", "-config", "ca.cnf", "-extensions", "v3_ca", "-subj", "/O=LOJO Private Networks/CN=Other CA", "-out", "other-ca.crt"])

        self.ca = try Self.der(ca, directory: directory)
        self.leaf = try Self.der(leaf, directory: directory)
        self.otherCA = try Self.der(other, directory: directory)
    }

    func assertOpenSSLVerifiesLeaf() throws {
        try Self.openssl(directory, ["verify", "-CAfile", "ca.crt", "leaf.crt"])
    }

    private static func der(_ pem: URL, directory: URL) throws -> Data {
        let out = directory.appendingPathComponent(pem.lastPathComponent + ".der")
        try openssl(directory, ["x509", "-in", pem.lastPathComponent, "-outform", "DER", "-out", out.lastPathComponent])
        return try Data(contentsOf: out)
    }

    private static func openssl(_ directory: URL, _ arguments: [String]) throws {
        let process = Process()
        process.currentDirectoryURL = directory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "openssl", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "openssl \(arguments.joined(separator: " "))\n\(text)"])
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let caConfig = """
    [ca]
    default_ca=CA_default
    [CA_default]
    dir=.
    database=demoCA/index.txt
    serial=demoCA/serial
    new_certs_dir=demoCA
    certificate=ca.crt
    private_key=ca.key
    default_md=sha256
    policy=policy_any
    x509_extensions=v3_leaf
    unique_subject=no
    [policy_any]
    commonName=supplied
    organizationName=optional
    [req]
    distinguished_name=dn
    x509_extensions=v3_ca
    prompt=no
    [dn]
    O=LOJO Private Networks
    CN=LOJO VPN site CA
    [v3_ca]
    basicConstraints=critical,CA:TRUE,pathlen:0
    keyUsage=critical,keyCertSign,cRLSign
    subjectKeyIdentifier=hash
    [v3_leaf]
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature
    extendedKeyUsage=serverAuth
    subjectAltName=IP:192.168.7.103,IP:100.96.1.18,IP:127.0.0.1,DNS:santacomputa,DNS:santacomputa.local,DNS:localhost
        subjectKeyIdentifier=hash
        authorityKeyIdentifier=keyid

    """
}

