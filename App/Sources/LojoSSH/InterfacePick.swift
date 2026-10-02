import Foundation

/// One interface from the phone's interface list. `ipv4` is nil when the interface is up with no IPv4 address.
public struct InterfaceAddress: Equatable, Sendable {
    public var name: String
    public var ipv4: String?

    public init(name: String, ipv4: String? = nil) {
        self.name = name
        self.ipv4 = ipv4
    }
}

/// Which of those interfaces is Wi‑Fi, cellular, or the LOJO overlay.
public struct InterfaceSelection: Equatable, Sendable {
    public var wifiIPv4: String?
    public var cellularActive: Bool
    public var vpnIPv4: String?
    public var vpnInterface: String?

    public init(wifiIPv4: String?, cellularActive: Bool, vpnIPv4: String?, vpnInterface: String?) {
        self.wifiIPv4 = wifiIPv4
        self.cellularActive = cellularActive
        self.vpnIPv4 = vpnIPv4
        self.vpnInterface = vpnInterface
    }
}

/// Picks the LOJO overlay by address, not by interface name.
///
/// `ipsec*` on iOS is also the 464XLAT CLAT interface (`192.0.0.0/29`, for example `ipsec6 192.0.0.6`).
/// That is cellular translation, not the VPN. The overlay is whichever interface owns an address in
/// `100.64.0.0/10` (OpenVPN Connect uses `utun`, currently `utun4 100.96.1.19`).
public enum InterfacePick {
    /// RFC 7050 / 464XLAT CLAT prefix. Never a VPN.
    public static let clat = IPv4Range(cidr: "192.0.0.0/29")!
    private static let linkLocal = IPv4Range(cidr: "169.254.0.0/16")!

    public static func select(_ interfaces: [InterfaceAddress]) -> InterfaceSelection {
        var wifi: String?
        var cellular = false
        var vpnIP: String?
        var vpnName: String?
        for iface in interfaces {
            if iface.name.hasPrefix("pdp_ip") { cellular = true }
            guard let ip = iface.ipv4, let value = IPv4Range.parse(ip) else { continue }
            if linkLocal.contains(value) || clat.contains(value) { continue }
            if iface.name == "en0" {
                wifi = ip
                continue
            }
            if iface.name.hasPrefix("pdp_ip") { continue }
            if vpnIP == nil, OverlayPolicy.overlay.contains(value) {
                vpnIP = ip
                vpnName = iface.name
            }
        }
        return InterfaceSelection(wifiIPv4: wifi, cellularActive: cellular, vpnIPv4: vpnIP, vpnInterface: vpnName)
    }
}

/// Whether an SSH host can be opened from this phone.
public enum HostAccess: Equatable, Sendable {
    case open
    /// Overlay address, and the overlay tunnel is not up.
    case needsOverlay
    /// Shop-LAN address. Reachable on site Wi‑Fi, or through the overlay's subnet route.
    case needsSiteWiFi
}

public enum HostGate {
    public static func access(address: String, policy: OverlayPolicy, overlayUp: Bool, wifiIPv4: String?) -> HostAccess {
        switch policy.reach(address: address) {
        case .overlay:
            return overlayUp ? .open : .needsOverlay
        case .routed(let range):
            if let wifiIPv4, let ip = IPv4Range.parse(wifiIPv4), range.contains(ip) { return .open }
            return overlayUp ? .open : .needsSiteWiFi
        case .refused:
            return .needsOverlay
        }
    }
}
