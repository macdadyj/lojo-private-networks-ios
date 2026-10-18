import LojoRemote
import XCTest

/// Talks to a real TLS listener signed by a private site CA.
/// The client is PinnedRelayTransport, the same type iPhone Remote Controller uses
/// after pairing. Nothing here stubs URLSession or the trust callback.
final class PinnedRelayHTTPSTests: XCTestCase {
    /// scripts/ios-unit-test.sh listens here with scripts/pinned-relay-https-server.py.
    private let port = 18443

    func testPinnedRelayTransportReadsPhonesFromASelfSignedSiteCA() async throws {
        let ca = try siteCA(named: "ca")
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)"))
        let phones = try await client(base: base, ca: ca).list()
        XCTAssertEqual(phones, [])
    }

    func testWrongSiteCAFailsTheHandshakeAndNamesTheURL() async throws {
        let ca = try siteCA(named: "other-ca")
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)"))
        do {
            _ = try await client(base: base, ca: ca).list()
            XCTFail("a different site CA was accepted")
        } catch {
            let summary = RemoteDiagnostics.summary(attempts: [(base, error)])
            XCTAssertTrue(summary.contains(base.absoluteString), summary)
            XCTAssertTrue(summary.contains("TLS pin mismatch"), summary)
        }
    }

    private func client(base: URL, ca: SiteCA) -> RelayClient {
        let transport = PinnedRelayTransport(pinning: PinningDelegate(anchor: ca), timeout: 8)
        return RelayClient(baseURL: base, networkCode: ca.sha256, transport: transport)
    }

    private func siteCA(named name: String) throws -> SiteCA {
        let bundle = Bundle(for: PinnedRelayHTTPSTests.self)
        let url = bundle.url(forResource: name, withExtension: "der")
            ?? bundle.url(forResource: name, withExtension: "der", subdirectory: "PinnedHTTPSFixture")
        let data = try Data(contentsOf: try XCTUnwrap(
            url,
            "Missing \(name).der. scripts/ios-unit-test.sh writes the site CA before this test."
        ))
        return try XCTUnwrap(SiteCA(der: data))
    }
}
