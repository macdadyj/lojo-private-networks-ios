import Combine
import Foundation
import LojoSSH
import SwiftTerm
import UIKit

enum TerminalError: Error, CustomStringConvertible {
    case vpnDown

    var description: String {
        switch self {
        case .vpnDown: return "Turn on LOJO VPN (OpenVPN Connect). SSH only runs over the private overlay."
        }
    }
}

/// One tab: a SwiftTerm view plus the SSH connection behind it, with keep-alive and reconnect.
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

    let id = UUID()
    let host: SSHHost
    @Published private(set) var phase: Phase = .connecting
    /// xterm title set by the remote shell; may contain the remote hostname.
    @Published private(set) var remoteTitle = ""
    /// Text a remote program asked to put on the clipboard (OSC 52), waiting for the owner's OK.
    @Published var pendingClipboard: String?

    var hostView: UIView { terminalView }
    var isLive: Bool { phase == .connected }

    private unowned let center: TerminalCenter
    private let terminalView: TerminalView
    private var connection: SSHConnection?
    private var shell: ShellChannel?
    private var runTask: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var hostKeyReply: CheckedContinuation<Bool, Never>?
    private var passwordReply: CheckedContinuation<String?, Never>?
    private var passwordToSave: String?
    private var userClosed = false
    private var hasConnected = false
    private var pingDropped = false
    /// Bumped whenever a connection is replaced, so callbacks from an old one are ignored.
    private var link = 0
    private var pendingCommand: String?

    private static let backoff = [1, 2, 5, 10, 30]
    private static let maxReconnectAttempts = 12

    init(host: SSHHost, center: TerminalCenter, command: String? = nil) {
        self.host = host
        self.center = center
        pendingCommand = command
        terminalView = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            font: .monospacedSystemFont(ofSize: CGFloat(center.fontSize), weight: .regular)
        )
        terminalView.terminalDelegate = self
        terminalView.optionAsMetaKey = true
        apply(theme: center.theme, fontSize: center.fontSize)
    }

    // MARK: Lifecycle

    func connect() {
        userClosed = false
        runTask?.cancel()
        teardown()
        phase = .connecting
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.establish()
            } catch {
                self.failed(error)
            }
        }
    }

    func close() {
        userClosed = true
        runTask?.cancel()
        hostKeyReply?.resume(returning: false)
        hostKeyReply = nil
        passwordReply?.resume(returning: nil)
        passwordReply = nil
        teardown()
    }

    /// Called when the app becomes active again: sockets may have died while suspended.
    func resumeIfDropped() {
        guard !userClosed else { return }
        if phase == .connected, connection?.isActive != true {
            dropped(nil)
        } else if case .reconnecting = phase {
            startReconnecting()
        } else if phase == .waitingForVPN {
            startReconnecting()
        }
    }

    private func establish() async throws {
        guard PhoneVPN.overlayAddress != nil else { throw TerminalError.vpnDown }
        let policy = center.hosts.policy
        let name = host.address
        let address = try await Task.detached { try policy.resolve(name) }.value
        let target = SSHTarget(address: address, port: host.port, username: host.username)
        let credentials = center.credentials(for: host)
        try Task.checkCancellation()

        let conn = try await SSHConnection.connect(
            to: target,
            credentials: credentials,
            passwordPrompt: { [weak self] in await self?.askPassword() },
            verifyHostKey: { [weak self] key in await self?.verify(key) ?? false }
        )
        guard !Task.isCancelled, !userClosed else {
            conn.close()
            throw CancellationError()
        }

        link += 1
        let token = link
        let term = terminalView.getTerminal()
        let channel: ShellChannel
        do {
            channel = try await conn.openShell(
                cols: term.cols, rows: term.rows,
                onOutput: { [weak self] bytes in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(bytes, token: token) } }
                },
                onExit: { [weak self] exit in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.shellExited(exit, token: token) } }
                }
            )
        } catch {
            conn.close()
            throw error
        }
        guard token == link, !userClosed else {
            channel.close()
            conn.close()
            throw CancellationError()
        }

        connection = conn
        shell = channel
        pingDropped = false
        conn.onClose { [weak self] reason in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionClosed(reason, token: token) } }
        }
        if hasConnected {
            banner("reconnected \(Self.clock.string(from: Date()))", color: 32)
        }
        hasConnected = true
        phase = .connected
        if let password = passwordToSave {
            center.keys.savePassword(password, hostID: host.id)
            passwordToSave = nil
        }
        startKeepAlive(conn)
        if let command = pendingCommand {
            pendingCommand = nil
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                self?.shell?.send(Array((command + "\r").utf8))
            }
        }
    }

    private func failed(_ error: Error) {
        if error is CancellationError || userClosed { return }
        if case .hostKeyChanged = phase { return }
        var text = Self.message(for: error)
        if case .authenticationFailed? = error as? SSHClientError, center.keys.keys.isEmpty {
            text += " There's no SSH key on this phone yet. Create one under Keys."
        }
        phase = .failed(text)
        Haptics.error()
    }

    private func teardown() {
        link += 1
        keepAlive?.cancel()
        keepAlive = nil
        shell?.close()
        shell = nil
        connection?.close()
        connection = nil
    }

    // MARK: Drops and reconnect

    private func received(_ bytes: [UInt8], token: Int) {
        guard token == link else { return }
        terminalView.feed(byteArray: bytes[...])
    }

    private func shellExited(_ exit: ShellExit, token: Int) {
        guard token == link, !userClosed else { return }
        if exit.isClean {
            teardown()
            let how = exit.status.map { "exit \($0)" } ?? exit.signal.map { "signal \($0)" } ?? "closed"
            banner("session ended (\(how))", color: 90)
            phase = .ended("Session ended (\(how))")
        } else {
            dropped(exit.error)
        }
    }

    private func connectionClosed(_ reason: SSHClientError?, token: Int) {
        guard token == link, !userClosed, phase == .connected else { return }
        dropped(reason)
    }

    private func dropped(_ reason: SSHClientError?) {
        let why = pingDropped ? SSHClientError.pingTimeout : reason
        teardown()
        banner("connection lost\(why.map { ": \($0.description)" } ?? "")", color: 33)
        startReconnecting()
    }

    private func startReconnecting() {
        runTask?.cancel()
        runTask = Task { [weak self] in await self?.reconnectLoop() }
    }

    private func reconnectLoop() async {
        var attempt = 0
        while !Task.isCancelled, !userClosed {
            guard PhoneVPN.overlayAddress != nil, center.isActive else {
                phase = .waitingForVPN
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
            phase = .reconnecting(attempt: attempt + 1, delay: delay)
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled || userClosed { return }
            do {
                try await establish()
                return
            } catch {
                if error is CancellationError { return }
                if case .hostKeyChanged = phase { return }
                if let ssh = error as? SSHClientError, ssh == .authenticationFailed || ssh == .hostKeyRejected {
                    failed(error)
                    return
                }
                attempt += 1
                if attempt >= Self.maxReconnectAttempts {
                    failed(error)
                    return
                }
            }
        }
    }

    private func startKeepAlive(_ conn: SSHConnection) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            var missed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                do {
                    try await conn.ping(timeout: .seconds(10))
                    missed = 0
                } catch {
                    missed += 1
                    if missed >= 2 {
                        self?.pingDropped = true
                        conn.close()
                        return
                    }
                }
            }
        }
    }

    // MARK: Prompts

    private func verify(_ key: HostKeyInfo) async -> Bool {
        let hosts = center.hosts
        switch hosts.knownHosts.verdict(address: host.address, port: host.port, key: key) {
        case .trusted:
            return true
        case .changed(let previous):
            phase = .hostKeyChanged(new: key, previous: previous)
            Haptics.error()
            return false
        case .unknown:
            if center.launch.autoTrusts(key.fingerprint) {
                hosts.trust(key, for: host, address: host.address)
                return true
            }
            let before = phase
            phase = .awaitingHostKey(key)
            Haptics.warning()
            let trusted = await withCheckedContinuation { hostKeyReply = $0 }
            if trusted {
                hosts.trust(key, for: host, address: host.address)
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

    private func banner(_ text: String, color: Int) {
        terminalView.feed(text: "\r\n\u{1b}[\(color)m— \(text) —\u{1b}[0m\r\n")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

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
        shell?.send(Array(data))
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
