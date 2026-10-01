import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct IPv4Range: Sendable, Hashable, CustomStringConvertible {
    public let base: UInt32
    public let prefix: Int

    public init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let ip = IPv4Range.parse(String(parts[0])),
              let bits = Int(parts[1]), (0...32).contains(bits) else { return nil }
        prefix = bits
        base = ip & IPv4Range.mask(bits)
    }

    public func contains(_ ip: UInt32) -> Bool { ip & IPv4Range.mask(prefix) == base }

    public var description: String {
        "\(base >> 24).\((base >> 16) & 0xff).\((base >> 8) & 0xff).\(base & 0xff)/\(prefix)"
    }

    static func mask(_ bits: Int) -> UInt32 { bits == 0 ? 0 : UInt32.max << (32 - UInt32(bits)) }

    public static func parse(_ s: String) -> UInt32? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var v: UInt32 = 0
        for o in octets {
            guard !o.isEmpty, o.count <= 3, o.allSatisfy(\.isNumber), let n = UInt32(o), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }
}

/// SSH only goes to the LOJO overlay (Connexa 100.64.0.0/10) or subnets LOJO routes over it.
public struct OverlayPolicy: Sendable, Equatable {
    public static let overlay = IPv4Range(cidr: "100.64.0.0/10")!
    public static let defaultRoutes: [IPv4Range] = [
        "192.168.7.0/24", "10.128.0.0/20", "10.77.0.0/24", "10.78.0.0/24",
        "10.79.0.0/24", "10.80.0.0/24", "10.90.0.0/24",
    ].compactMap(IPv4Range.init(cidr:))
    public static let privateSuffixes = [".lan"]

    public var routes: [IPv4Range]

    public init(routes: [IPv4Range] = OverlayPolicy.defaultRoutes) {
        self.routes = routes
    }

    public enum Reach: Sendable, Equatable {
        case overlay
        /// A LOJO-routed LAN behind a Connexa connector, reached through the overlay.
        case routed(IPv4Range)
        case refused
    }

    public func reach(address: String) -> Reach {
        guard let ip = IPv4Range.parse(address) else { return .refused }
        if Self.overlay.contains(ip) { return .overlay }
        if let route = routes.first(where: { $0.contains(ip) }) { return .routed(route) }
        return .refused
    }

    public func allows(address: String) -> Bool {
        reach(address: address) != .refused
    }

    /// Returns an IPv4 literal the policy allows, resolving `*.lan` names; anything public is refused
    /// before a single packet goes to it.
    public func resolve(_ host: String) throws -> String {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if IPv4Range.parse(h) != nil {
            guard allows(address: h) else {
                throw SSHClientError.notOverlay("\(h) is not on the LOJO overlay")
            }
            return h
        }
        guard Self.privateSuffixes.contains(where: { h.hasSuffix($0) }) else {
            throw SSHClientError.notOverlay("Only overlay addresses or *.lan names are allowed")
        }
        for ip in Self.lookupIPv4(h) where allows(address: ip) {
            return ip
        }
        throw SSHClientError.notOverlay("\(h) does not resolve to an overlay address")
    }

    static func lookupIPv4(_ name: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            if let sa = ai.pointee.ai_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil {
                    out.append(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
            }
            cur = ai.pointee.ai_next
        }
        return out
    }
}
