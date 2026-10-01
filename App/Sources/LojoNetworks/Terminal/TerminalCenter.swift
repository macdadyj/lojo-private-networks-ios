import Combine
import Foundation
import LojoSSH

/// QA hooks for the Terminal tab (docs/ssh-terminal.md §8). The DEBUG-only ones can type into a
/// shell or trust a host key, so release builds ignore them.
struct TerminalLaunch: Sendable {
    enum Screen: String, Sendable {
        case hosts, keys, key, settings, edit, diag
    }

    var screen: Screen?
    /// Host label for `edit` and `diag` ("gateway" is the seeded gateway host; default gateway).
    var host: String?
    /// Comma-separated host labels to open sessions to at launch ("gateway" is the seeded gateway host).
    var connect: String?
    var redact = false
    /// Pull the gateway device list at launch even if the cached one is fresh.
    var refresh = false
    var run: String?
    var trustFingerprint: String?
    var gatewayPort: Int?
    var ensureKey = false

    func autoTrusts(_ fingerprint: String) -> Bool {
        guard let trustFingerprint else { return false }
        return trustFingerprint == fingerprint
    }

    static let current: TerminalLaunch = {
        let env = ProcessInfo.processInfo.environment
        func text(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }
        func flag(_ key: String) -> Bool {
            ["1", "true", "yes", "on"].contains(text(key)?.lowercased() ?? "")
        }
        var launch = TerminalLaunch(
            screen: text("LOJO_SSH_SCREEN").flatMap { Screen(rawValue: $0.lowercased()) },
            host: text("LOJO_SSH_HOST"),
            connect: text("LOJO_SSH_CONNECT"),
            redact: flag("LOJO_SSH_REDACT"),
            refresh: flag("LOJO_SSH_REFRESH")
        )
        #if DEBUG
        launch.run = text("LOJO_SSH_RUN")
        launch.trustFingerprint = text("LOJO_SSH_TRUST_FP")
        launch.gatewayPort = text("LOJO_SSH_GATEWAY_PORT").flatMap(Int.init)
        launch.ensureKey = flag("LOJO_SSH_ENSURE_KEY")
        #endif
        return launch
    }()
}

/// Owns every open session plus the host, key and directory stores for the Terminal tab.
@MainActor
final class TerminalCenter: ObservableObject {
    enum DirectoryState: Equatable {
        case idle, loading
        case failed(String)
    }

    let hosts = HostStore()
    let keys: SSHKeyStore
    let launch = TerminalLaunch.current

    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published var showingSession = false
    @Published private(set) var directoryState: DirectoryState = .idle
    @Published private(set) var vpnAddress: String?
    @Published var theme: TerminalTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme); restyle() }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize); restyle() }
    }
    @Published var redact: Bool {
        didSet { defaults.set(redact, forKey: Keys.redact) }
    }

    private(set) var isActive = true
    var launchApplied = false
    private let defaults = UserDefaults.standard
    private var vpnMonitor: Task<Void, Never>?

    nonisolated static let fontRange: ClosedRange<Double> = 9...24
    static let directoryCommand = "$HOME/.local/bin/lojo-ssh-directory --json"

    private enum Keys {
        static let theme = "lojo.ssh.theme"
        static let fontSize = "lojo.ssh.fontSize"
        static let redact = "lojo.ssh.redact"
    }

    init() {
        keys = SSHKeyStore(directory: hosts.directoryURL)
        theme = TerminalTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .lojoDark
        let size = defaults.double(forKey: Keys.fontSize)
        fontSize = Self.fontRange.contains(size) ? size : 13
        redact = launch.redact || defaults.bool(forKey: Keys.redact)
        vpnAddress = PhoneVPN.overlayAddress
        vpnMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refreshVPN()
            }
        }
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } ?? sessions.last }

    func refreshVPN() {
        let now = PhoneVPN.overlayAddress
        if now != vpnAddress { vpnAddress = now }
    }

    func sceneChanged(active: Bool) {
        isActive = active
        guard active else { return }
        refreshVPN()
        sessions.forEach { $0.resumeIfDropped() }
    }

    // MARK: Sessions

    @discardableResult
    func open(_ host: SSHHost) -> TerminalSession {
        let command = sessions.isEmpty ? launch.run : nil
        let session = TerminalSession(host: host, center: self, command: command)
        sessions.append(session)
        selectedID = session.id
        showingSession = true
        session.connect()
        return session
    }

    func close(_ session: TerminalSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = sessions.last?.id }
        if sessions.isEmpty { showingSession = false }
    }

    func show(_ session: TerminalSession) {
        selectedID = session.id
        showingSession = true
    }

    /// Opens a gateway-list device, saving it first with its default user and port.
    func open(_ entry: DirectoryEntry) {
        open(hosts.save(entry))
    }

    /// The key to put in a host's authorized_keys: its chosen key, else a Secure Enclave key, else any.
    func authorizeKey(for host: SSHHost) -> SSHKeyRecord? {
        if let id = host.keyID, let chosen = keys.keys.first(where: { $0.id == id }) { return chosen }
        return keys.keys.first { $0.kind == .secureEnclaveP256 } ?? keys.keys.first
    }

    func launchHost() -> SSHHost? {
        guard let wanted = launch.host?.lowercased(), wanted != "gateway" else { return hosts.gateway }
        return hosts.hosts.first { $0.label.lowercased() == wanted }
    }

    /// The host's chosen key (or every key on the phone), then its saved password if any.
    func credentials(for host: SSHHost) -> [SSHCredential] {
        let chosen = host.keyID.map { id in keys.keys.filter { $0.id == id } } ?? keys.keys
        var result: [SSHCredential] = chosen.compactMap { record in
            (try? keys.privateKey(record)).map(SSHCredential.key)
        }
        if let password = keys.password(hostID: host.id) {
            result.append(.password(password))
        }
        return result
    }

    private func restyle() {
        sessions.forEach { $0.apply(theme: theme, fontSize: fontSize) }
    }

    // MARK: Gateway directory

    /// True once the gateway's host key is trusted and the VPN is up, so a refresh can't prompt.
    var canRefreshDirectory: Bool {
        guard vpnAddress != nil, let gateway = hosts.gateway else { return false }
        return !hosts.savedHostKeys(for: gateway).isEmpty && directoryState != .loading
    }

    var directoryIsStale: Bool {
        guard let generated = hosts.directory?.generatedAt,
              let date = ISO8601DateFormatter().date(from: generated) else { return true }
        return Date().timeIntervalSince(date) > 600
    }

    /// Runs `lojo-ssh-directory` on the gateway over SSH. Only against a gateway whose host key is
    /// already trusted: this path never prompts.
    func refreshDirectory() async {
        guard let gateway = hosts.gateway else {
            directoryState = .failed("No gateway host is set up.")
            return
        }
        guard !hosts.savedHostKeys(for: gateway).isEmpty else {
            directoryState = .failed("Connect to the site gateway once and trust its host key, then pull the device list.")
            return
        }
        guard PhoneVPN.overlayAddress != nil else {
            directoryState = .failed(TerminalError.vpnDown.description)
            return
        }
        directoryState = .loading
        do {
            let policy = hosts.policy
            let name = gateway.address
            let address = try await Task.detached { try policy.resolve(name) }.value
            let known = hosts.knownHosts
            let conn = try await SSHConnection.connect(
                to: SSHTarget(address: address, port: gateway.port, username: gateway.username),
                credentials: credentials(for: gateway),
                verifyHostKey: { key in known.verdict(address: gateway.address, port: gateway.port, key: key) == .trusted }
            )
            defer { conn.close() }
            let (output, exit) = try await conn.exec(Self.directoryCommand)
            switch exit.status {
            case 0?:
                break
            case 127?:
                throw DirectoryError.notInstalled
            default:
                throw DirectoryError.failed(exit.status)
            }
            let snapshot = try JSONDecoder().decode(DirectorySnapshot.self, from: output)
            hosts.setDirectory(snapshot, raw: output)
            directoryState = .idle
        } catch let error as DecodingError {
            directoryState = .failed("The gateway sent a device list this app can't read (\(error.localizedDescription)).")
        } catch {
            directoryState = .failed(TerminalSession.message(for: error))
        }
    }
}

enum DirectoryError: Error, CustomStringConvertible {
    case notInstalled
    case failed(Int?)

    var description: String {
        switch self {
        case .notInstalled:
            return "lojo-ssh-directory isn't installed on the gateway (copy gateway/lojo-ssh-directory to ~/.local/bin)."
        case .failed(let status):
            return "lojo-ssh-directory failed on the gateway (exit \(status.map(String.init) ?? "?"))."
        }
    }
}
