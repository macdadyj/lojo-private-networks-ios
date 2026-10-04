import Foundation
import LojoSSH

struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var label: String
    var address: String
    var port: Int
    var username: String
    var group: String
    /// nil: offer every key on the phone.
    var keyID: String?
    var isGateway: Bool
    /// Attach this host's tabs to a tmux session so the shell survives a dropped connection.
    var keepSessionsAlive: Bool
    /// When on, tmux captures the mouse. Off keeps scrolling and copy in the phone's terminal.
    var tmuxMouse: Bool

    var endpoint: String { port == 22 ? address : "\(address):\(port)" }

    init(
        id: UUID = UUID(),
        label: String,
        address: String,
        port: Int = 22,
        username: String,
        group: String = "Hosts",
        keyID: String? = nil,
        isGateway: Bool = false,
        keepSessionsAlive: Bool = true,
        tmuxMouse: Bool = false
    ) {
        self.id = id
        self.label = label
        self.address = address
        self.port = port
        self.username = username
        self.group = group
        self.keyID = keyID
        self.isGateway = isGateway
        self.keepSessionsAlive = keepSessionsAlive
        self.tmuxMouse = tmuxMouse
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, address, port, username, group, keyID, isGateway, keepSessionsAlive, tmuxMouse
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decode(String.self, forKey: .label)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "Hosts"
        keyID = try container.decodeIfPresent(String.self, forKey: .keyID)
        isGateway = try container.decodeIfPresent(Bool.self, forKey: .isGateway) ?? false
        let settings = try HostSessionSettings(from: decoder)
        keepSessionsAlive = settings.keepSessionsAlive
        tmuxMouse = settings.tmuxMouse
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(address, forKey: .address)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(group, forKey: .group)
        try container.encodeIfPresent(keyID, forKey: .keyID)
        try container.encode(isGateway, forKey: .isGateway)
        try container.encode(keepSessionsAlive, forKey: .keepSessionsAlive)
        try container.encode(tmuxMouse, forKey: .tmuxMouse)
    }
}

/// Login user and port for the LOJO devices we know, keyed by address. Seeded as hosts on first
/// launch and used whenever a device is saved from the gateway list.
struct HostDefaults: Sendable, Hashable {
    var label: String
    var address: String
    var username: String
    var port: Int
    var group: String

    static let known: [HostDefaults] = [
        HostDefaults(label: "santacomputa", address: "100.96.1.18", username: "jon", port: 2222, group: "Gateway"),
        HostDefaults(label: "labMachine", address: "100.96.1.90", username: "jon", port: 22, group: "Lab"),
        HostDefaults(label: "Vision Pi", address: "100.96.1.115", username: "pi", port: 22, group: "Pis"),
        HostDefaults(label: "BlueBox", address: "192.168.7.42", username: "jon", port: 22, group: "Shop LAN"),
    ]

    static func match(address: String) -> HostDefaults? {
        known.first { $0.address == address }
    }

    /// User for a gateway-list device: the known default, then the gateway's hint, then a guess.
    static func username(for entry: DirectoryEntry) -> String {
        if let known = match(address: entry.address) { return known.username }
        if let user = entry.user, !user.isEmpty { return user }
        let name = entry.name.lowercased()
        return name.contains("pi") || name.contains("vision") ? "pi" : "jon"
    }

    static func port(for entry: DirectoryEntry) -> Int {
        match(address: entry.address)?.port ?? entry.port
    }
}

/// One-line shell command that appends a public key to the login user's authorized_keys, once.
enum AuthorizeCommand {
    static func text(publicKey: String) -> String {
        let key = quoted(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && { grep -qxF \(key) ~/.ssh/authorized_keys 2>/dev/null || echo \(key) >> ~/.ssh/authorized_keys; } && chmod 600 ~/.ssh/authorized_keys"
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
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
