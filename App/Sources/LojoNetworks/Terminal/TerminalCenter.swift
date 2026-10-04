import Combine
import Foundation
import LojoSSH
import UIKit

/// QA hooks for the Terminal tab (docs/ssh-terminal.md §8). The DEBUG-only ones can type into a
/// shell or trust a host key, so release builds ignore them.
struct TerminalLaunch: Sendable {
    enum Screen: String, Sendable {
        case hosts, keys, key, settings, edit, diag, sessions, reconnecting
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
    /// DEBUG screenshot hook: session list and reconnecting indicator use sample data and do not dial.
    var preview = false

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
        launch.preview = flag("LOJO_SSH_PREVIEW")
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
    @Published private(set) var wifiIPv4: String?
    /// Set from a successful overlay probe. The interface list can miss utun while the probe still went out it.
    @Published private(set) var overlayProbeUp = false
    var overlayIsUp: Bool { vpnAddress != nil || overlayProbeUp }
    @Published var theme: TerminalTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme); restyle() }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize); restyle() }
    }
    @Published var redact: Bool {
        didSet { defaults.set(redact, forKey: Keys.redact) }
    }

    var launchApplied = false
    private let defaults = UserDefaults.standard
    private var vpnMonitor: Task<Void, Never>?
    private var pathDebounce: Task<Void, Never>?
    private let pathWatcher = PathWatcher()
    private let backgroundLease = BackgroundLease()
    private var sceneIsBackground = false

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
        let phone = PhoneInterfaces.current()
        vpnAddress = phone.vpnIPv4
        wifiIPv4 = phone.wifiIPv4
        vpnMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refreshVPN()
            }
        }
        pathWatcher.start { [weak self] in
            self?.networkPathChanged()
        }
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } ?? sessions.last }

    func refreshVPN() {
        let phone = PhoneInterfaces.current()
        let changed = phone.vpnIPv4 != vpnAddress || phone.wifiIPv4 != wifiIPv4
        if phone.vpnIPv4 != vpnAddress { vpnAddress = phone.vpnIPv4 }
        if phone.wifiIPv4 != wifiIPv4 { wifiIPv4 = phone.wifiIPv4 }
        if changed { sessions.forEach { $0.networkChanged() } }
    }

    func setOverlayProbe(_ up: Bool) {
        if overlayProbeUp != up { overlayProbeUp = up }
    }

    func access(to address: String) -> HostAccess {
        HostGate.access(address: address, policy: hosts.policy, overlayUp: overlayIsUp, wifiIPv4: wifiIPv4)
    }

    /// Background keeps the socket (via a short `beginBackgroundTask`) and the terminal view.
    /// Returning to the foreground probes a live socket and reattaches immediately if it died.
    func noteScene(inBackground: Bool) {
        if inBackground {
            guard !sceneIsBackground else { return }
            sceneIsBackground = true
            sessions.forEach { $0.sceneDidBackground() }
        } else {
            guard sceneIsBackground else { return }
            sceneIsBackground = false
            refreshVPN()
            sessions.forEach { $0.sceneDidForeground() }
        }
    }

    func noteBackground(begin: Bool) {
        if begin { backgroundLease.begin() } else { backgroundLease.end() }
    }

    private func networkPathChanged() {
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.refreshVPN()
            self.sessions.forEach { $0.networkChanged() }
        }
    }

    // MARK: Sessions

    @discardableResult
    func open(_ host: SSHHost, tmuxSession: String? = nil) -> TerminalSession {
        let command = sessions.isEmpty ? launch.run : nil
        let name = resolvedTmuxName(tmuxSession, for: host)
        let session = TerminalSession(host: host, center: self, command: command, tmuxSessionName: name)
        sessions.append(session)
        selectedID = session.id
        showingSession = true
        session.connect()
        return session
    }

    #if DEBUG
    func openReconnectingPreview() {
        let host = SSHHost(label: "Demo host", address: "100.64.0.2", port: 22, username: "owner", group: "Demo")
        let session = TerminalSession(
            host: host, center: self, tmuxSessionName: TmuxCommand.sessionName(forLabel: host.label)
        )
        session.parkReconnectingPreview()
        sessions.append(session)
        selectedID = session.id
        showingSession = true
    }
    #endif

    /// Shows a tab already attached to `name`, or opens one that attaches to it.
    func attachTmuxSession(named name: String, on host: SSHHost) {
        guard TmuxCommand.isSafeName(name) else { return }
        if let existing = sessions.first(where: { $0.tmuxSessionName == name && $0.host.id == host.id }) {
            show(existing)
            return
        }
        open(host, tmuxSession: name)
    }

    private func resolvedTmuxName(_ requested: String?, for host: SSHHost) -> String {
        if let requested, TmuxCommand.isSafeName(requested) { return requested }
        return nextTmuxName(for: host)
    }

    private func nextTmuxName(for host: SSHHost) -> String {
        let used = Set(sessions.filter { $0.host.id == host.id }.map(\.tmuxSessionName))
        let base = TmuxCommand.sessionName(forLabel: host.label)
        if !used.contains(base) { return base }
        var generation = 2
        while used.contains(TmuxCommand.sessionName(forLabel: host.label, generation: generation)) {
            generation += 1
        }
        return TmuxCommand.sessionName(forLabel: host.label, generation: generation)
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

    // MARK: tmux sessions on a host

    func listTmuxSessions(on host: SSHHost) async throws -> [TmuxRemoteSession] {
        let conn = try await connected(to: host)
        defer { conn.close() }
        let (output, exit) = try await conn.exec(TmuxCommand.listCommand())
        if TmuxCommand.listIsEmpty(status: exit.status, output: output) { return [] }
        guard exit.status == 0 else {
            throw TmuxListError.failed("The host couldn't list tmux sessions (exit \(exit.status.map(String.init) ?? "?")).")
        }
        return TmuxCommand.parseSessionList(String(decoding: output, as: UTF8.self))
    }

    func killTmuxSession(_ name: String, on host: SSHHost) async throws {
        guard let command = TmuxCommand.killCommand(session: name) else { throw TmuxListError.refusedName }
        let conn = try await connected(to: host)
        defer { conn.close() }
        let (_, exit) = try await conn.exec(command)
        guard exit.status == 0 else {
            throw TmuxListError.failed("The host didn't end \(name) (exit \(exit.status.map(String.init) ?? "?")).")
        }
    }

    private func connected(to host: SSHHost) async throws -> SSHConnection {
        switch access(to: host.address) {
        case .open:
            break
        case .needsOverlay:
            throw TerminalError.vpnDown
        case .needsSiteWiFi:
            throw TerminalError.needsSiteWiFi
        }
        guard !hosts.savedHostKeys(for: host).isEmpty else { throw TmuxListError.untrusted }
        let policy = hosts.policy
        let name = host.address
        let address = try await Task.detached { try policy.resolve(name) }.value
        let known = hosts.knownHosts
        return try await SSHConnection.connect(
            to: SSHTarget(address: address, port: host.port, username: host.username),
            credentials: credentials(for: host),
            verifyHostKey: { key in known.verdict(address: host.address, port: host.port, key: key) == .trusted }
        )
    }

    // MARK: Gateway directory

    /// True once the gateway's host key is trusted and the VPN is up, so a refresh can't prompt.
    var canRefreshDirectory: Bool {
        guard overlayIsUp, let gateway = hosts.gateway else { return false }
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
        guard overlayIsUp else {
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

enum TmuxListError: Error, CustomStringConvertible {
    case untrusted
    case refusedName
    case failed(String)

    var description: String {
        switch self {
        case .untrusted:
            return "Connect to this host once and trust its host key, then list its sessions."
        case .refusedName:
            return "That session name can't be ended from here."
        case .failed(let text):
            return text
        }
    }
}

/// One `beginBackgroundTask` shared by every live terminal, so iOS leaves the socket up briefly
/// after the app leaves the foreground. It does not keep the app running in the background.
@MainActor
private final class BackgroundLease {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var holders = 0

    func begin() {
        holders += 1
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "LOJO Terminal") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
    }

    func end() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        expire()
    }

    private func expire() {
        holders = 0
        guard id != .invalid else { return }
        let current = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(current)
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
