import Darwin
import Foundation
import Network

/// What the phone itself is attached to, read from the kernel's interface list.
/// Addresses stay on-device; they are shown on the Connection Check screen only.
struct PhoneInterfaces: Sendable, Equatable {
    var wifiIPv4: String?
    var cellularActive: Bool
    var vpnIPv4: String?
    var vpnInterface: String?

    var hasWiFi: Bool { wifiIPv4 != nil }
    var hasVPN: Bool { vpnIPv4 != nil }
    var vpnSummary: String? { vpnIPv4.map { "\(vpnInterface ?? "utun") \($0)" } }

    static func current() -> PhoneInterfaces {
        var result = PhoneInterfaces(wifiIPv4: nil, cellularActive: false, vpnIPv4: nil, vpnInterface: nil)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard let ip = ipv4String(addr) else { continue }
            if name == "en0" {
                result.wifiIPv4 = ip
            } else if name.hasPrefix("pdp_ip") {
                result.cellularActive = true
            } else if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
                if !ip.hasPrefix("169.254.") {
                    result.vpnIPv4 = ip
                    result.vpnInterface = name
                }
            }
        }
        return result
    }

    private static func ipv4String(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { return nil }
        return String(cCharBuffer: host)
    }
}

extension String {
    init(cCharBuffer buf: [CChar]) {
        self = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Fires when the phone's network path changes (Wi‑Fi joins, VPN toggles, cellular handoff).
@MainActor
final class PathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lojo.path")
    private var started = false
    private var sawInitialPath = false

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The monitor reports the current path immediately on start; only react to changes.
                if !self.sawInitialPath {
                    self.sawInitialPath = true
                    return
                }
                onChange()
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
