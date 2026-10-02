import Darwin
import Foundation
import LojoSSH
import Network

/// One line of an on-screen diagnostics report.
struct DiagLine: Sendable, Hashable, Identifiable {
    enum Status: Sendable { case ok, fail, info, skip }

    let label: String
    let value: String
    let status: Status

    var id: String { label + value }
}

/// Everything learned about one path (LAN or overlay) to the site gateway.
struct PathReport: Sendable, Identifiable {
    let path: ConnectionPath
    let address: String
    let lines: [DiagLine]
    let probe: ProbeResult?
    let tcpOK: Bool
    let totalMs: Int
    var protection: GatewayEndpoint.Protection = .none

    var id: String { address }
    var reachable: Bool { probe?.reachable == true }
    var title: String {
        switch protection {
        case .tls: return "\(path.longTitle) · HTTPS"
        case .vpnOnly, .none: return "\(path.longTitle) · HTTP (legacy)"
        }
    }
}

enum PathDiagnostics {
    static let stepTimeout: TimeInterval = 5

    static func run(_ endpoint: GatewayEndpoint, anchor: SiteCA?) async -> PathReport {
        let started = Date()
        var lines: [DiagLine] = []
        let url = endpoint.baseURL
        let host = url.host ?? ""
        let port = UInt16(GatewayAddress.port(of: url))
        let hostClass = GatewayAddress.classify(host)

        lines.append(DiagLine(label: "Address", value: url.absoluteString, status: .info))
        lines.append(DiagLine(label: "Type", value: hostClass.title, status: .info))
        switch endpoint.protection {
        case .tls:
            lines.append(DiagLine(label: "Scheme", value: "HTTPS (TLS, pinned site CA)", status: .info))
            if let anchor {
                lines.append(DiagLine(label: "Pin", value: "Site CA \(anchor.shortFingerprint) (Keychain)", status: .ok))
            } else {
                lines.append(DiagLine(label: "Pin", value: "Not paired — no site CA in the Keychain", status: .fail))
            }
        case .vpnOnly:
            lines.append(DiagLine(label: "Scheme", value: "HTTP (legacy) — encrypted by the VPN only", status: .info))
        case .none:
            lines.append(DiagLine(label: "Scheme", value: "HTTP (legacy) — unencrypted", status: .info))
        }

        var connectHost = host
        if hostClass.isLiteral {
            lines.append(DiagLine(label: "DNS", value: "Not needed (IP address)", status: .skip))
        } else {
            let dns = await resolve(host)
            if let first = dns.addresses.first {
                connectHost = first
                let shown = dns.addresses.prefix(3).joined(separator: ", ")
                lines.append(DiagLine(label: "DNS", value: "\(shown) in \(dns.ms) ms", status: .ok))
            } else {
                lines.append(DiagLine(label: "DNS", value: "Failed after \(dns.ms) ms — \(dns.error ?? "no addresses")", status: .fail))
            }
        }

        let tcp = await TCPProbe.connect(host: connectHost, port: port, timeout: stepTimeout)
        if tcp.ok {
            var via = tcp.interfaceText ?? "unknown interface"
            if let local = tcp.localAddress { via += " from \(local)" }
            lines.append(DiagLine(label: "TCP \(port)", value: "Connected in \(tcp.ms) ms via \(via)", status: .ok))
        } else {
            lines.append(DiagLine(label: "TCP \(port)", value: "\(tcp.error ?? "Failed") after \(tcp.ms) ms", status: .fail))
        }

        let probe = await GatewayClient.probe(endpoint, anchor: anchor, timeout: stepTimeout)
        if endpoint.secure {
            if probe.reachable {
                var parts = [probe.tls?.version ?? "TLS", "chain verified to site CA"]
                if let leaf = probe.tls?.leafSHA256 {
                    parts.append("leaf " + SiteCA.pairs(leaf).prefix(4).joined(separator: ":") + "…")
                }
                if let until = ISODate.parse(probe.network?.tls?.leafNotAfter) {
                    parts.append("until \(until.formatted(date: .abbreviated, time: .omitted))")
                }
                lines.append(DiagLine(label: "TLS", value: parts.joined(separator: " · "), status: .ok))
            } else if let tls = probe.error?.tlsFailure {
                lines.append(DiagLine(label: "TLS", value: tls.technical + (tls.detail.map { " — \($0)" } ?? ""), status: .fail))
            } else if tcp.ok {
                lines.append(DiagLine(label: "TLS", value: "No TLS result (\(probe.error?.technical ?? "no reply"))", status: .fail))
            } else {
                lines.append(DiagLine(label: "TLS", value: "Not attempted (no TCP connection)", status: .skip))
            }
        }
        if let net = probe.network {
            lines.append(DiagLine(label: endpoint.secure ? "HTTPS" : "HTTP", value: "200 OK in \(probe.latencyMs ?? 0) ms", status: .ok))
            var gw = "\(net.gateway.name) · hub \(net.hub.connected ? "connected" : "OFFLINE")"
            if let via = net.arrivedVia { gw += " · arrived via \(via)" }
            if let scheme = net.scheme { gw += " as \(scheme)" }
            lines.append(DiagLine(label: "Gateway", value: gw, status: net.hub.connected ? .ok : .fail))
            if let name = net.site?.name {
                lines.append(DiagLine(label: "Site", value: name, status: .info))
            }
            if let seen = net.seenFrom {
                lines.append(DiagLine(label: "Seen as", value: seen, status: .info))
            }
        } else if let err = probe.error {
            let ms = probe.elapsedMs.map { " after \($0) ms" } ?? ""
            lines.append(DiagLine(label: endpoint.secure ? "HTTPS" : "HTTP", value: "\(err.technical)\(ms)", status: .fail))
            lines.append(DiagLine(label: "Meaning", value: err.errorDescription ?? "", status: .info))
        }

        return PathReport(
            path: endpoint.path,
            address: url.absoluteString,
            lines: lines,
            probe: probe,
            tcpOK: tcp.ok,
            totalMs: Int(Date().timeIntervalSince(started) * 1000),
            protection: endpoint.protection
        )
    }

    static func resolve(_ host: String) async -> (addresses: [String], ms: Int, error: String?) {
        await Task.detached {
            let start = Date()
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, nil, &hints, &res)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard rc == 0, let first = res else {
                return ([], ms, String(cString: gai_strerror(rc)))
            }
            defer { freeaddrinfo(res) }
            var out: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let ai = cursor {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(cCharBuffer: buf)
                    if !out.contains(s) { out.append(s) }
                }
                cursor = ai.pointee.ai_next
            }
            return (out, ms, nil)
        }.value
    }

    static func phoneSummary(_ p: PhoneInterfaces) -> [DiagLine] {
        [
            DiagLine(label: "Wi‑Fi", value: p.wifiIPv4 ?? "Not connected", status: p.hasWiFi ? .ok : .skip),
            DiagLine(label: "Cellular", value: p.cellularActive ? "Active" : "Off", status: p.cellularActive ? .ok : .skip),
            DiagLine(label: "VPN tunnel", value: p.vpnSummary ?? "None detected", status: p.hasVPN ? .ok : .skip),
        ]
    }
}

/// Raw TCP connect with Network framework. App Transport Security does not apply here, so a
/// TCP success next to an HTTP ATS failure pins the problem on ATS rather than the network.
enum TCPProbe {
    struct Result: Sendable {
        let ok: Bool
        let ms: Int
        let localAddress: String?
        let interfaceText: String?
        let error: String?
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    static func connect(host: String, port: UInt16, timeout: TimeInterval) async -> Result {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return Result(ok: false, ms: 0, localAddress: nil, interfaceText: nil, error: "Bad port")
        }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = Int(timeout)
        }
        // No requiredInterface. The overlay route (100.64.0.0/10) leaves via utun; pinning
        // the socket to cellular, or to ipsec (the 464XLAT CLAT), would miss that route.
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let once = Once()
        let start = Date()
        let queue = DispatchQueue(label: "lojo.tcpprobe")

        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            @Sendable func finish(_ r: Result) {
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: r)
            }
            @Sendable func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let path = conn.currentPath
                    var local: String?
                    if case .hostPort(let h, _)? = path?.localEndpoint {
                        local = "\(h)".components(separatedBy: "%").first
                    }
                    var iface: String?
                    if let i = chosenInterface(local: local, interfaces: path?.availableInterfaces ?? []) {
                        iface = "\(i.name) (\(interfaceKind(i)))"
                    }
                    finish(Result(ok: true, ms: elapsed(), localAddress: local, interfaceText: iface, error: nil))
                case .waiting(let err), .failed(let err):
                    finish(Result(ok: false, ms: elapsed(), localAddress: nil, interfaceText: nil, error: describe(err)))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(Result(ok: false, ms: elapsed(), localAddress: nil, interfaceText: nil, error: "No TCP answer (timed out)"))
            }
        }
    }

    /// The interface that owns the local address. `availableInterfaces.first` can be the
    /// cellular CLAT (`ipsec`) even when the source address is the overlay on `utun`.
    private static func chosenInterface(local: String?, interfaces: [NWInterface]) -> NWInterface? {
        guard let first = interfaces.first else { return nil }
        guard let local, let value = IPv4Range.parse(local) else {
            return interfaces.first { !$0.name.hasPrefix("ipsec") } ?? first
        }
        if OverlayPolicy.overlay.contains(value) {
            return interfaces.first { $0.name.hasPrefix("utun") }
                ?? interfaces.first { !$0.name.hasPrefix("ipsec") }
                ?? first
        }
        if InterfacePick.clat.contains(value) {
            return interfaces.first { $0.name.hasPrefix("ipsec") } ?? first
        }
        return interfaces.first { !$0.name.hasPrefix("ipsec") } ?? first
    }

    private static func interfaceKind(_ i: NWInterface) -> String {
        // ipsec is also the cellular 464XLAT interface. Only utun is the OpenVPN overlay.
        if i.name.hasPrefix("utun") { return "VPN tunnel" }
        if i.name.hasPrefix("ipsec") { return "ipsec" }
        switch i.type {
        case .wifi: return "Wi‑Fi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "Ethernet"
        case .loopback: return "loopback"
        default: return "other"
        }
    }

    private static func describe(_ err: NWError) -> String {
        switch err {
        case .posix(let code):
            let name: String
            switch code {
            case .ECONNREFUSED: name = "Connection refused (ECONNREFUSED)"
            case .EHOSTUNREACH: name = "No route to host (EHOSTUNREACH)"
            case .ENETUNREACH: name = "Network unreachable (ENETUNREACH)"
            case .ENETDOWN: name = "Network down (ENETDOWN)"
            case .ETIMEDOUT: name = "Timed out (ETIMEDOUT)"
            case .ECONNRESET: name = "Connection reset (ECONNRESET)"
            default: name = "POSIX error \(code.rawValue)"
            }
            return name
        case .dns(let code): return "DNS error \(code)"
        case .tls(let code): return "TLS error \(code)"
        default: return "\(err)"
        }
    }
}
