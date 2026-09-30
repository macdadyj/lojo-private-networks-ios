import Foundation
import Network

/// Normalizes what an owner types ("100.96.1.18", "gw.site.lan:8801", "http://10.0.0.5") into a
/// gateway base URL, and classifies the host so diagnostics can explain routing and ATS behavior.
enum GatewayAddress {
    static let defaultPort = 8801
    static let defaultTLSPort = 8443

    static func port(of url: URL) -> Int {
        url.port ?? (url.scheme == "https" ? defaultTLSPort : defaultPort)
    }

    /// The same host on the gateway's legacy plain-HTTP port.
    static func legacy(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "http"
        comps.port = defaultPort
        return comps.url
    }

    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var comps = URLComponents(string: text),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty
        else { return nil }
        comps.scheme = scheme
        if comps.port == nil { comps.port = scheme == "https" ? defaultTLSPort : defaultPort }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    static func validationMessage(_ raw: String) -> String? {
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter an IP address or host name." }
        return normalize(raw) == nil ? "Use an address like https://100.96.0.10 or gateway.example.lan:8801." : nil
    }

    enum HostClass: Sendable {
        case privateLAN, overlay, linkLocal, loopback, publicIP, ipv6, mdns, hostname

        var title: String {
            switch self {
            case .privateLAN: return "Private LAN address (RFC 1918)"
            case .overlay: return "Overlay address (100.64.0.0/10)"
            case .linkLocal: return "Link-local address"
            case .loopback: return "Loopback"
            case .publicIP: return "Public IP address"
            case .ipv6: return "IPv6 address"
            case .mdns: return ".local name (Bonjour — same Wi‑Fi only, never over VPN)"
            case .hostname: return "Host name (needs DNS)"
            }
        }

        var isLiteral: Bool {
            switch self {
            case .mdns, .hostname: return false
            default: return true
            }
        }
    }

    static func classify(_ host: String) -> HostClass {
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (10, _): return .privateLAN
            case (172, 16...31): return .privateLAN
            case (192, 168): return .privateLAN
            case (100, 64...127): return .overlay
            case (169, 254): return .linkLocal
            case (127, _): return .loopback
            default: return .publicIP
            }
        }
        if IPv6Address(host) != nil { return .ipv6 }
        if host.lowercased().hasSuffix(".local") { return .mdns }
        return .hostname
    }
}
