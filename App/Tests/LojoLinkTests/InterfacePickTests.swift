import XCTest
@testable import LojoLink

/// The iPhone 14 cellular path reports `ipsec6 192.0.0.6` (464XLAT CLAT) next to the real
/// OpenVPN overlay `utun4 100.96.1.19`. The overlay is the address in 100.64.0.0/10.
final class InterfacePickTests: XCTestCase {
    private let phone = [
        InterfaceAddress(name: "ipsec6", ipv4: "192.0.0.6"),
        InterfaceAddress(name: "utun4", ipv4: "100.96.1.19"),
        InterfaceAddress(name: "pdp_ip0"),
        InterfaceAddress(name: "en0"),
    ]

    func testPhoneFixtureSelectsTheOverlayUtun() {
        let picked = InterfacePick.select(phone)
        XCTAssertNil(picked.wifiIPv4)
        XCTAssertTrue(picked.cellularActive)
        XCTAssertEqual(picked.vpnIPv4, "100.96.1.19")
        XCTAssertEqual(picked.vpnInterface, "utun4")
    }

    func testLaterClatDoesNotOverwriteTheOverlay() {
        let picked = InterfacePick.select([
            InterfaceAddress(name: "en0"),
            InterfaceAddress(name: "pdp_ip0"),
            InterfaceAddress(name: "utun4", ipv4: "100.96.1.19"),
            InterfaceAddress(name: "ipsec6", ipv4: "192.0.0.6"),
        ])
        XCTAssertEqual(picked.vpnIPv4, "100.96.1.19")
        XCTAssertEqual(picked.vpnInterface, "utun4")
        XCTAssertNil(picked.wifiIPv4)
        XCTAssertTrue(picked.cellularActive)
    }

    func testClatAloneIsNotAVpn() {
        let picked = InterfacePick.select([
            InterfaceAddress(name: "ipsec6", ipv4: "192.0.0.6"),
            InterfaceAddress(name: "pdp_ip0", ipv4: "10.8.1.4"),
            InterfaceAddress(name: "en0"),
        ])
        XCTAssertNil(picked.vpnIPv4)
        XCTAssertNil(picked.vpnInterface)
        XCTAssertNil(picked.wifiIPv4)
        XCTAssertTrue(picked.cellularActive)
    }

    func testClatPrefixEndsAt192_0_0_7() {
        let clat = InterfacePick.clat
        XCTAssertTrue(clat.contains(IPv4Range.parse("192.0.0.0")!))
        XCTAssertTrue(clat.contains(IPv4Range.parse("192.0.0.6")!))
        XCTAssertTrue(clat.contains(IPv4Range.parse("192.0.0.7")!))
        XCTAssertFalse(clat.contains(IPv4Range.parse("192.0.0.8")!))
        let outside = InterfacePick.select([
            InterfaceAddress(name: "ipsec6", ipv4: "192.0.0.8"),
        ])
        XCTAssertNil(outside.vpnIPv4)
    }

    func testShopWiFiIsWiFiNotVpn() {
        let picked = InterfacePick.select([
            InterfaceAddress(name: "ipsec6", ipv4: "192.0.0.6"),
            InterfaceAddress(name: "en0", ipv4: "192.168.7.50"),
            InterfaceAddress(name: "pdp_ip0"),
        ])
        XCTAssertEqual(picked.wifiIPv4, "192.168.7.50")
        XCTAssertNil(picked.vpnIPv4)
        XCTAssertTrue(picked.cellularActive)
    }

    func testLinkLocalAndForeignUtunAreNotTheOverlay() {
        let picked = InterfacePick.select([
            InterfaceAddress(name: "utun4", ipv4: "169.254.1.1"),
            InterfaceAddress(name: "utun3", ipv4: "10.8.0.2"),
            InterfaceAddress(name: "en0", ipv4: "169.254.10.2"),
        ])
        XCTAssertNil(picked.vpnIPv4)
        XCTAssertNil(picked.wifiIPv4)
        XCTAssertFalse(picked.cellularActive)
    }

    func testFirstOverlayAddressWins() {
        let picked = InterfacePick.select([
            InterfaceAddress(name: "utun4", ipv4: "100.96.1.19"),
            InterfaceAddress(name: "utun5", ipv4: "100.96.1.20"),
        ])
        XCTAssertEqual(picked.vpnInterface, "utun4")
        XCTAssertEqual(picked.vpnIPv4, "100.96.1.19")
    }

    func testHostGateOpensOverlayHostsWhenTheTunnelIsUp() {
        let policy = OverlayPolicy()
        for address in ["100.96.1.18", "100.96.1.90", "100.96.1.115"] {
            XCTAssertEqual(
                HostGate.access(address: address, policy: policy, overlayUp: true, wifiIPv4: nil),
                .open,
                address
            )
            XCTAssertEqual(
                HostGate.access(address: address, policy: policy, overlayUp: false, wifiIPv4: nil),
                .needsOverlay,
                address
            )
        }
    }

    func testBlueBoxNeedsSiteWiFiUnlessTheOverlayOrShopLanIsUp() {
        let policy = OverlayPolicy()
        let blue = "192.168.7.42"
        XCTAssertEqual(HostGate.access(address: blue, policy: policy, overlayUp: false, wifiIPv4: nil), .needsSiteWiFi)
        XCTAssertEqual(HostGate.access(address: blue, policy: policy, overlayUp: false, wifiIPv4: "10.0.0.8"), .needsSiteWiFi)
        XCTAssertEqual(HostGate.access(address: blue, policy: policy, overlayUp: false, wifiIPv4: "192.168.7.20"), .open)
        XCTAssertEqual(HostGate.access(address: blue, policy: policy, overlayUp: true, wifiIPv4: nil), .open)
    }
}
