import Combine
import Foundation
import LojoSSH
import LojoTerminalScroll
import SwiftTerm
import UIKit

enum TerminalError: Error, CustomStringConvertible {
    case vpnDown
    case needsSiteWiFi

    var description: String {
        switch self {
        case .vpnDown: return "Turn on LOJO VPN (OpenVPN Connect). SSH only runs over the private overlay."
        case .needsSiteWiFi: return "Needs site Wi‑Fi. This address is on the shop LAN, not the overlay."
        }
    }
}

enum TmuxNotice: Equatable {
    case missing
    case unknown

    var text: String {
        switch self {
        case .missing: return TmuxCommand.missingNotice
        case .unknown: return TmuxCommand.unknownNotice
        }
    }
}

/// One tab: a SwiftTerm view plus the SSH connection behind it. With "Keep sessions alive" the
/// remote command is tmux, so the shell keeps running on the host when this socket drops.
/// SwiftTerm is only imported here and in nothing that also imports SwiftUI, because both
/// define `Color`.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case awaitingHostKey(HostKeyInfo)
        case awaitingPassword
        case connected
        case waitingForVPN
        case reconnecting(attempt: Int, delay: Int)
        case hostKeyChanged(new: HostKeyInfo, previous: [KnownHosts.Entry])
        case ended(String)
        case failed(String)
    }

    enum RemoteShellKind: Equatable {
        case unknown
        case tmux
        case plain
    }

    let id = UUID()
    let host: SSHHost
    /// Stable for the life of this tab, including reconnects. A second tab gets another name.
    let tmuxSessionName: String
    @Published private(set) var phase: Phase = .connecting
    /// Why the last attempt failed, for the failure card's actions.
    @Published private(set) var failure: SSHClientError?
    /// xterm title set by the remote shell; may contain the remote hostname.
    @Published private(set) var remoteTitle = ""
    /// Text a remote program asked to put on the clipboard (OSC 52), waiting for the owner's OK.
    @Published var pendingClipboard: String?
    @Published private(set) var shellKind: RemoteShellKind = .unknown
    /// Set when persistence was requested and tmux could not be used. The install command is never run.
    @Published private(set) var tmuxNotice: TmuxNotice?
    @Published var tmuxNoticeDismissed = false

    var hostView: UIView { terminalView }
    var isLive: Bool { phase == .connected }

    func attachScroll() {
        scroll.attach(terminalView)
    }
    /// Latest saved host, so the persistence toggle applies on the next attach.
    var displayHost: SSHHost { center.hosts.hosts.first { $0.id == host.id } ?? host }

    /// Last connect or login failure. Shown while reconnecting, and on the failure card when retries stop.
    private(set) var lastConnectError: String?

    var statusLine: String {
        switch phase {
        case .connected:
            return shellKind == .tmux ? TmuxCommand.keptOnHostStatus : "Connected"
        case .reconnecting(let attempt, let delay):
            return SessionLinkMachine.reconnectLine(attempt: attempt, delay: delay, error: lastConnectError)
        case .waitingForVPN:
            if center.access(to: displayHost.address) == .needsSiteWiFi { return "Needs site Wi‑Fi" }
            return phase.summary
        default:
            return phase.summary
        }
    }

    private unowned let center: TerminalCenter
    private let terminalView: TerminalView
    private var connection: SSHConnection?
    private var shell: ShellChannel?
    private var runTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var hostKeyReply: CheckedContinuation<Bool, Never>?
    private var passwordReply: CheckedContinuation<String?, Never>?
    private var passwordToSave: String?
    private var userClosed = false
    private var hasConnected = false
    private var previewOnly = false
    var showsSampleSessions: Bool { previewOnly }
    /// Bumped whenever a connection is replaced, so callbacks from an old one are ignored.
    private var generation = 0
    /// Bumped when a new dial starts, so a slow older dial cannot publish success.
    private var attemptID = 0
    private var pendingCommand: String?
    private var linkMachine = SessionLinkMachine()
    private var inputBuffer = TerminalInputBuffer()
    let scroll = TerminalScrollController()

    init(host: SSHHost, center: TerminalCenter, command: String? = nil, tmuxSessionName: String) {
        self.host = host
        self.center = center
        self.tmuxSessionName = tmuxSessionName
        pendingCommand = command
        terminalView = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            font: .monospacedSystemFont(ofSize: CGFloat(center.fontSize), weight: .regular)
        )
        terminalView.terminalDelegate = self
        terminalView.optionAsMetaKey = true
        apply(theme: center.theme, fontSize: center.fontSize)
        scroll.attach(terminalView)
    }

    #if DEBUG
    /// Screenshot hook: show the reconnecting indicator without opening a socket.
    func parkReconnectingPreview() {
        previewOnly = true
        shellKind = .tmux
        phase = .reconnecting(attempt: 2, delay: 4)
    }

    /// Screenshot / UI-test hook: fill the terminal with a flood of output, no socket.
    func parkOutputPreview(lines: Int, alternate: Bool) {
        previewOnly = true
        shellKind = .plain
        phase = .connected
        scroll.attach(terminalView)
        if alternate {
            terminalView.feed(text: TerminalFlood.enterAlternateScreen())
            terminalView.feed(text: "Grok TUI\r\n" + TerminalFlood.lines(min(max(lines, 1), 48), prefix: "tui"))
        } else {
            terminalView.feed(text: TerminalFlood.lines(max(lines, 1)))
        }
        scroll.previewReady(lines: max(lines, 1), alternate: alternate)
    }
    #endif

    // MARK: Lifecycle

    func connect() {
        reconnectNow()
    }

    func reconnectNow() {
        guard !previewOnly else { return }
        userClosed = false
        failure = nil
        if case .ended = phase { phase = .connecting }
        if case .failed = phase { phase = .connecting }
        if case .hostKeyChanged = phase { return }
        apply(linkMachine.handle(.userReconnect))
    }

    func close() {
        userClosed = true
        attemptID += 1
        runTask?.cancel()
        hostKeyReply?.resume(returning: false)
        hostKeyReply = nil
        passwordReply?.resume(returning: nil)
        passwordReply = nil
        inputBuffer.clear()
        apply(linkMachine.handle(.userClose))
    }

    func sceneDidBackground() {
        guard !previewOnly else { return }
        apply(linkMachine.handle(.sceneBackground))
    }

    func sceneDidForeground() {
        guard !previewOnly else { return }
        if center.access(to: displayHost.address) != .open {
            apply(linkMachine.handle(.pathUnavailable))
            apply(linkMachine.handle(.sceneForeground))
        } else {
            apply(linkMachine.handle(.sceneForeground))
            if case .waitingForPath = linkMachine.state {
                apply(linkMachine.handle(.pathAvailable))
            }
        }
    }

    func networkChanged() {
        guard !previewOnly else { return }
        switch phase {
        case .awaitingHostKey, .awaitingPassword, .hostKeyChanged:
            return
        default:
            break
        }
        switch center.access(to: displayHost.address) {
        case .open:
            switch linkMachine.state {
            case .waitingForPath, .failed:
                apply(linkMachine.handle(.pathAvailable))
            case .connecting, .live, .backoff, .ended:
                apply(linkMachine.handle(.networkChanged))
            }
        case .needsOverlay, .needsSiteWiFi:
            apply(linkMachine.handle(.pathUnavailable))
        }
    }

    private func apply(_ effects: [SessionLinkMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .openSocket:
                switch phase {
                case .awaitingHostKey, .awaitingPassword, .hostKeyChanged:
                    break
                default:
                    startEstablish()
                }
            case .closeSocket:
                attemptID += 1
                runTask?.cancel()
                teardownSocket()
            case .scheduleWait(let seconds):
                waitTask?.cancel()
                waitTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard let self, !Task.isCancelled else { return }
                    self.apply(self.linkMachine.handle(.waitElapsed))
                }
            case .cancelWait:
                waitTask?.cancel()
                waitTask = nil
            case .beginBackgroundTask:
                center.noteBackground(begin: true)
            case .endBackgroundTask:
                center.noteBackground(begin: false)
            case .flushInput:
                hasConnected = true
                let term = terminalView.getTerminal()
                shell?.resize(
                    cols: TmuxCommand.clampDimension(term.cols, fallback: 80),
                    rows: TmuxCommand.clampDimension(term.rows, fallback: 24)
                )
                let typed = inputBuffer.drain()
                if !typed.isEmpty { shell?.send(typed) }
            case .probeSocket:
                startProbe()
            }
        }
        publishPhase()
    }

    private func startEstablish() {
        attemptID += 1
        let attempt = attemptID
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.establish(attempt: attempt)
                guard self.attemptID == attempt, !Task.isCancelled, !self.userClosed else { return }
                self.lastConnectError = nil
                self.apply(self.linkMachine.handle(.connectSucceeded))
                self.startKeepAlive()
            } catch is CancellationError {
                return
            } catch {
                guard self.attemptID == attempt, !Task.isCancelled, !self.userClosed else { return }
                self.handleEstablishError(error)
            }
        }
    }

    private func establish(attempt: Int) async throws {
        switch center.access(to: displayHost.address) {
        case .open:
            break
        case .needsOverlay:
            throw TerminalError.vpnDown
        case .needsSiteWiFi:
            throw TerminalError.needsSiteWiFi
        }
        let saved = displayHost
        let policy = center.hosts.policy
        let name = saved.address
        let address = try await Task.detached { try policy.resolve(name) }.value
        guard attempt == attemptID else { throw CancellationError() }
        let target = SSHTarget(address: address, port: saved.port, username: saved.username)
        let credentials = center.credentials(for: saved)
        try Task.checkCancellation()

        let conn = try await SSHConnection.connect(
            to: target,
            credentials: credentials,
            passwordPrompt: { [weak self] in await self?.askPassword() },
            verifyHostKey: { [weak self] key in await self?.verify(key) ?? false }
        )
        do {
            guard attempt == attemptID, !Task.isCancelled, !userClosed else {
                conn.close()
                throw CancellationError()
            }
            try await finishEstablish(conn, host: saved, attempt: attempt)
        } catch {
            conn.close()
            throw error
        }
    }

    private func finishEstablish(_ conn: SSHConnection, host: SSHHost, attempt: Int) async throws {
        let term = terminalView.getTerminal()
        let cols = TmuxCommand.clampDimension(term.cols, fallback: 80)
        let rows = TmuxCommand.clampDimension(term.rows, fallback: 24)
        let kind = try await remoteKind(on: conn, host: host, attempt: attempt)

        generation += 1
        let token = generation
        let channel: ShellChannel
        do {
            switch kind {
            case .tmux:
                let attach = TmuxAttach(
                    session: tmuxSessionName, columns: cols, rows: rows, mouse: host.tmuxMouse
                )
                channel = try await conn.openCommand(
                    attach.execCommand, term: TmuxCommand.term, cols: cols, rows: rows,
                    onOutput: { [weak self] bytes in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(bytes, token: token) } }
                    },
                    onExit: { [weak self] exit in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.shellExited(exit, token: token) } }
                    }
                )
                shellKind = .tmux
                tmuxNotice = nil
            case .plain(let notice):
                channel = try await conn.openShell(
                    term: TmuxCommand.term, cols: cols, rows: rows,
                    onOutput: { [weak self] bytes in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(bytes, token: token) } }
                    },
                    onExit: { [weak self] exit in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.shellExited(exit, token: token) } }
                    }
                )
                shellKind = .plain
                if tmuxNotice != notice { tmuxNoticeDismissed = false }
                tmuxNotice = notice
            }
        } catch {
            conn.close()
            throw error
        }
        guard token == generation, attempt == attemptID, !userClosed else {
            channel.close()
            conn.close()
            throw CancellationError()
        }

        connection = conn
        shell = channel
        conn.onClose { [weak self] reason in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionClosed(reason, token: token) } }
        }
        if terminalView.window != nil { focus() }
        if let password = passwordToSave {
            center.keys.savePassword(password, hostID: host.id)
            passwordToSave = nil
        }
        if let command = pendingCommand {
            pendingCommand = nil
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.generation == token else { return }
                self.shell?.send(Array((command + "\r").utf8))
            }
        }
    }

    private enum RemoteKind {
        case tmux
        case plain(TmuxNotice?)
    }

    /// Probe only. A missing tmux binary falls back to a login shell; the install command is not sent.
    private func remoteKind(on conn: SSHConnection, host: SSHHost, attempt: Int) async throws -> RemoteKind {
        guard host.keepSessionsAlive else { return .plain(nil) }
        do {
            let (output, exit) = try await conn.exec(TmuxCommand.probeCommand)
            guard attempt == attemptID else { throw CancellationError() }
            if !conn.isActive { throw SSHClientError.disconnected("connection closed") }
            if TmuxCommand.probeFound(status: exit.status, output: output) { return .tmux }
            return .plain(.missing)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !conn.isActive { throw error }
            return .plain(.unknown)
        }
    }

    private func handleEstablishError(_ error: Error) {
        if case .hostKeyChanged = phase {
            apply(linkMachine.handle(.connectFailed(retryable: false)))
            return
        }
        if error is TerminalError {
            lastConnectError = Self.message(for: error)
            apply(linkMachine.handle(.pathUnavailable))
            return
        }
        let text = Self.message(for: error)
        lastConnectError = text
        if Self.isRetryable(error) {
            apply(linkMachine.handle(.connectFailed(retryable: true)))
            if case .failed = linkMachine.state {
                phase = .failed(text)
                failure = error as? SSHClientError
                _ = terminalView.resignFirstResponder()
                Haptics.error()
            }
            return
        }
        failed(error)
        apply(linkMachine.handle(.connectFailed(retryable: false)))
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let ssh = error as? SSHClientError else { return true }
        if ssh.isAuthFailure || ssh == .hostKeyRejected { return false }
        return true
    }

    private func failed(_ error: Error) {
        if error is CancellationError || userClosed { return }
        if case .hostKeyChanged = phase { return }
        var text = Self.message(for: error)
        if (error as? SSHClientError)?.isAuthFailure == true {
            text += center.keys.keys.isEmpty
                ? ". Create a key under Keys, then add it on the host."
                : ". Add this iPhone's public key on the host: copy the authorize command below and run it there."
        }
        failure = error as? SSHClientError
        phase = .failed(text)
        _ = terminalView.resignFirstResponder()
        Haptics.error()
    }

    private func teardownSocket() {
        generation += 1
        keepAlive?.cancel()
        keepAlive = nil
        probeTask?.cancel()
        probeTask = nil
        shell?.close()
        shell = nil
        connection?.close()
        connection = nil
    }

    private func publishPhase() {
        switch phase {
        case .awaitingHostKey, .awaitingPassword, .hostKeyChanged, .ended, .failed:
            return
        case .connecting, .connected, .waitingForVPN, .reconnecting:
            break
        }
        switch linkMachine.state {
        case .connecting:
            if hasConnected || linkMachine.attempt > 0 {
                phase = .reconnecting(attempt: max(linkMachine.attempt, 1), delay: 0)
            } else {
                phase = .connecting
            }
        case .live:
            phase = .connected
        case .backoff(let attempt, let delay):
            phase = .reconnecting(attempt: attempt, delay: delay)
        case .waitingForPath:
            phase = .waitingForVPN
        case .failed, .ended:
            break
        }
    }

    // MARK: Drops and reconnect

    private func received(_ bytes: [UInt8], token: Int) {
        guard token == generation else { return }
        terminalView.feed(byteArray: bytes[...])
        scroll.noteOutput(bytes[...])
    }

    private func shellExited(_ exit: ShellExit, token: Int) {
        guard token == generation, !userClosed else { return }
        if exit.isClean {
            let how = exit.status.map { "exit \($0)" } ?? exit.signal.map { "signal \($0)" } ?? "closed"
            phase = .ended("Session ended (\(how))")
            _ = terminalView.resignFirstResponder()
            apply(linkMachine.handle(.cleanExit))
        } else {
            apply(linkMachine.handle(.socketClosed))
        }
    }

    private func connectionClosed(_: SSHClientError?, token: Int) {
        guard token == generation, !userClosed else { return }
        switch linkMachine.state {
        case .live, .connecting:
            apply(linkMachine.handle(.socketClosed))
        case .backoff, .waitingForPath, .failed, .ended:
            break
        }
    }

    private func startProbe() {
        probeTask?.cancel()
        let token = generation
        probeTask = Task { [weak self] in
            guard let self else { return }
            guard let conn = self.connection, conn.isActive else {
                guard self.generation == token else { return }
                self.apply(self.linkMachine.handle(.socketClosed))
                return
            }
            do {
                try await conn.ping(timeout: .seconds(5))
                guard !Task.isCancelled, self.generation == token else { return }
                self.apply(self.linkMachine.handle(.pingSucceeded))
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.apply(self.linkMachine.handle(.socketClosed))
            }
        }
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        let token = generation
        guard let conn = connection else { return }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, self.generation == token else { return }
                do {
                    try await conn.ping(timeout: .seconds(10))
                    guard self.generation == token else { return }
                    self.apply(self.linkMachine.handle(.pingSucceeded))
                } catch {
                    guard self.generation == token else { return }
                    self.apply(self.linkMachine.handle(.pingMissed))
                }
            }
        }
    }

    // MARK: Prompts

    private func verify(_ key: HostKeyInfo) async -> Bool {
        let saved = displayHost
        let hosts = center.hosts
        switch hosts.knownHosts.verdict(address: saved.address, port: saved.port, key: key) {
        case .trusted:
            return true
        case .changed(let previous):
            phase = .hostKeyChanged(new: key, previous: previous)
            Haptics.error()
            return false
        case .unknown:
            if center.launch.autoTrusts(key.fingerprint) {
                hosts.trust(key, for: saved, address: saved.address)
                return true
            }
            let before = phase
            phase = .awaitingHostKey(key)
            Haptics.warning()
            let trusted = await withCheckedContinuation { hostKeyReply = $0 }
            if trusted {
                hosts.trust(key, for: saved, address: saved.address)
                phase = before
            }
            return trusted
        }
    }

    func answerHostKey(trust: Bool) {
        hostKeyReply?.resume(returning: trust)
        hostKeyReply = nil
    }

    private func askPassword() async -> String? {
        let before = phase
        phase = .awaitingPassword
        let answer = await withCheckedContinuation { passwordReply = $0 }
        if phase == .awaitingPassword { phase = before }
        return answer
    }

    func answerPassword(_ password: String?, save: Bool) {
        passwordToSave = save ? password : nil
        passwordReply?.resume(returning: password)
        passwordReply = nil
    }

    func acceptClipboard(_ allow: Bool) {
        if allow, let text = pendingClipboard { UIPasteboard.general.string = text }
        pendingClipboard = nil
    }

    // MARK: Screen actions

    func apply(theme: TerminalTheme, fontSize: Double) {
        let palette = theme.palette
        terminalView.installColors(palette.ansi.map(Self.color))
        terminalView.nativeForegroundColor = UIColor(rgb: palette.fg)
        terminalView.nativeBackgroundColor = UIColor(rgb: palette.bg)
        terminalView.caretColor = UIColor(rgb: palette.caret)
        terminalView.keyboardAppearance = theme == .solarizedLight ? .light : .dark
        let size = CGFloat(fontSize)
        if terminalView.font.pointSize != size {
            terminalView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func paste() {
        terminalView.paste(nil)
    }

    /// Copies the selection; returns false when nothing is selected.
    func copySelection() -> Bool {
        guard terminalView.selectionActive, let text = terminalView.getSelection(), !text.isEmpty else { return false }
        UIPasteboard.general.string = text
        terminalView.selectNone()
        return true
    }

    func toggleKeyboard() {
        if terminalView.isFirstResponder {
            _ = terminalView.resignFirstResponder()
        } else {
            _ = terminalView.becomeFirstResponder()
        }
    }

    func focus() {
        _ = terminalView.becomeFirstResponder()
    }

    private static func color(_ rgb: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((rgb >> 16) & 0xff) * 257,
            green: UInt16((rgb >> 8) & 0xff) * 257,
            blue: UInt16(rgb & 0xff) * 257
        )
    }

    static func message(for error: Error) -> String {
        switch error {
        case let e as SSHClientError: return e.description
        case let e as TerminalError: return e.description
        case let e as DirectoryError: return e.description
        case let e as TmuxListError: return e.description
        case let e as KeychainError: return e.description
        case let e as KeyImportError: return e.description
        default: return error.localizedDescription
        }
    }
}

extension TerminalSession: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        shell?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        remoteTitle = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        if let shell, phase == .connected {
            shell.send(bytes)
        } else {
            inputBuffer.append(bytes)
        }
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {
        Haptics.light()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        let text = String(decoding: content, as: UTF8.self)
        if !text.isEmpty { pendingClipboard = text }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}
