import Foundation
import LojoSSH

struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var label: String
    var address: String
    var port: Int = 22
    var username: String
    var group: String = "Hosts"
    /// nil: offer every key on the phone.
    var keyID: String?
    var isGateway = false

    var endpoint: String { port == 22 ? address : "\(address):\(port)" }
}

/// One row of `lojo-ssh-directory --json` from the gateway.
struct DirectoryEntry: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var address: String
    var kind: String
    var group: String
    var online: Bool
    var sshOpen: Bool
    var port: Int
    var user: String?

    var id: String { "\(address):\(port)" }
}

struct DirectorySnapshot: Codable, Sendable {
    var version: Int
    var generatedAt: String
    var gateway: String?
    var routes: [String]
    var devices: [DirectoryEntry]
}

enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
    case lojoDark, solarizedDark, solarizedLight, green

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lojoDark: return "LOJO Dark"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .green: return "Classic Green"
        }
    }

    /// Foreground, background, caret, then the 16 ANSI colors, as 0xRRGGBB.
    var palette: (fg: UInt32, bg: UInt32, caret: UInt32, ansi: [UInt32]) {
        let xterm: [UInt32] = [
            0x1d1f21, 0xcc6666, 0x5fb37c, 0xe0b25c, 0x5c8fd6, 0xb294bb, 0x3fb6b8, 0xc5c8c6,
            0x666a6e, 0xff7b72, 0x7ee2a0, 0xf6d078, 0x81a9f0, 0xd2b0e0, 0x6fe0e2, 0xffffff,
        ]
        let solarized: [UInt32] = [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
        ]
        switch self {
        case .lojoDark: return (0xdde3ea, 0x0e1621, 0x10b0b4, xterm)
        case .solarizedDark: return (0x93a1a1, 0x002b36, 0x93a1a1, solarized)
        case .solarizedLight: return (0x586e75, 0xfdf6e3, 0x586e75, solarized)
        case .green: return (0x33ff66, 0x000000, 0x33ff66, xterm)
        }
    }
}

/// Addresses on screen, optionally masked for screenshots and screen sharing.
enum AddressDisplay {
    static func text(_ address: String, redact: Bool) -> String {
        guard redact else { return address }
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return "•••" }
        return "\(parts[0]).\(parts[1]).•.•"
    }
}

/// The phone side of the overlay-only rule: SSH needs the LOJO VPN tunnel up.
enum PhoneVPN {
    static var overlayAddress: String? {
        guard let ip = PhoneInterfaces.current().vpnIPv4, let v = IPv4Range.parse(ip),
              OverlayPolicy.overlay.contains(v) else { return nil }
        return ip
    }
}
