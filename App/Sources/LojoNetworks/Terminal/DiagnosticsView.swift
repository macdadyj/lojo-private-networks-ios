import LojoSSH
import SwiftUI
import UIKit

/// Step-by-step check of one host: VPN, route, TCP, SSH banner, host key, login. Never opens a
/// shell, and never authenticates to a host whose key is unknown or changed.
@MainActor
final class HostDiagnostics: ObservableObject {
    enum Status: Equatable { case pending, running, pass, warn, fail, skipped }

    enum Kind: String, CaseIterable, Identifiable {
        case vpn, route, tcp, banner, hostKey, login
        var id: String { rawValue }

        var title: String {
            switch self {
            case .vpn: return "LOJO VPN"
            case .route: return "Route"
            case .tcp: return "TCP connect"
            case .banner: return "SSH banner"
            case .hostKey: return "Host key"
            case .login: return "Login"
            }
        }
    }

    struct Step: Identifiable, Equatable {
        let kind: Kind
        var status: Status = .pending
        var detail = ""
        var millis: Double?
        var id: Kind { kind }
    }

    @Published private(set) var steps = Kind.allCases.map { Step(kind: $0) }
    @Published private(set) var running = false
    @Published private(set) var offeredKey: HostKeyInfo?
    @Published private(set) var verdict: KnownHosts.Verdict?
    @Published private(set) var authFailure: AuthFailure?

    let host: SSHHost
    private unowned let center: TerminalCenter
    private var address: String?

    init(host: SSHHost, center: TerminalCenter) {
        self.host = host
        self.center = center
    }

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        steps = Kind.allCases.map { Step(kind: $0) }
        offeredKey = nil
        verdict = nil
        authFailure = nil
        address = nil

        checkVPN()

        set(.route, .running)
        let policy = center.hosts.policy
        let name = host.address
        let lookupStart = ContinuousClock.now
        let resolved: String
        do {
            resolved = try await Task.detached { try policy.resolve(name) }.value
        } catch {
            set(.route, .fail, TerminalSession.message(for: error))
            skip(from: .tcp, "Not tried")
            return
        }
        address = resolved
        var route = resolved == name ? "" : "\(name) → \(mask(resolved)) · "
        switch policy.reach(address: resolved) {
        case .overlay:
            route += "LOJO overlay address, straight through the VPN tunnel"
        case .routed(let range):
            route += "On \(mask(range)), a LOJO-routed LAN: the overlay connector forwards it"
        case .refused:
            route += "Refused by the overlay policy"
        }
        set(.route, .pass, route, millis: resolved == name ? nil : SSHProbe.millis(since: lookupStart))

        set(.tcp, .running)
        let tcpStart = ContinuousClock.now
        let probe = await SSHProbe.banner(address: resolved, port: host.port)
        guard let connectMillis = probe.connectMillis else {
            var why = probe.error?.description ?? "Can’t connect"
            if PhoneVPN.overlayAddress == nil { why += " The LOJO VPN is off." }
            set(.tcp, .fail, why, millis: SSHProbe.millis(since: tcpStart))
            skip(from: .banner, "Not tried")
            return
        }
        set(.tcp, .pass, "Port \(host.port) is open", millis: connectMillis)
        guard let banner = probe.banner else {
            set(.banner, .fail, probe.error?.description ?? "No SSH banner")
            skip(from: .hostKey, "Not tried")
            return
        }
        set(.banner, .pass, banner)

        await checkLogin()
    }

    /// Saves the key the host just offered (the owner checked the fingerprint), then retries login.
    func trustOfferedKey() async {
        guard let key = offeredKey, verdict == .unknown else { return }
        center.hosts.trust(key, for: host, address: host.address)
        Haptics.success()
        running = true
        defer { running = false }
        await checkLogin()
    }

    private func checkVPN() {
        set(.vpn, .running)
        let phone = PhoneInterfaces.current()
        let interface = phone.vpnInterface ?? "utun"
        if let ip = PhoneVPN.overlayAddress {
            set(.vpn, .pass, "\(interface) · \(mask(ip))")
        } else if let ip = phone.vpnIPv4 {
            set(.vpn, .fail, "A VPN is up (\(interface) \(mask(ip))) but it has no LOJO overlay address (100.64.0.0/10). Switch OpenVPN Connect to the LOJO profile.")
        } else {
            set(.vpn, .fail, "No VPN tunnel. Turn on the LOJO profile in OpenVPN Connect.")
        }
    }

    private func checkLogin() async {
        guard let address else { return }
        set(.hostKey, .running)
        set(.login, .pending)
        authFailure = nil
        let start = ContinuousClock.now
        do {
            let conn = try await SSHConnection.connect(
                to: SSHTarget(address: address, port: host.port, username: host.username),
                credentials: center.credentials(for: host),
                verifyHostKey: { [weak self] key in await self?.sawHostKey(key) ?? false }
            )
            conn.close()
            set(.login, .pass, "Logged in as \(host.username) with \(conn.authenticatedWith). No shell was opened.", millis: SSHProbe.millis(since: start))
            Haptics.success()
        } catch let error as SSHClientError {
            switch error {
            case .hostKeyRejected:
                set(.login, .skipped, verdict == .unknown
                    ? "Not tried: check and trust the host key first"
                    : "Not tried: the host key changed, so nothing was sent")
            case .authenticationFailed(let auth):
                authFailure = auth
                set(.login, .fail, auth.description, millis: SSHProbe.millis(since: start))
                Haptics.error()
            default:
                if offeredKey == nil {
                    set(.hostKey, .fail, error.description)
                    set(.login, .skipped, "Not tried")
                } else {
                    set(.login, .fail, error.description, millis: SSHProbe.millis(since: start))
                }
            }
        } catch {
            set(.login, .fail, TerminalSession.message(for: error))
        }
    }

    private func sawHostKey(_ key: HostKeyInfo) -> Bool {
        offeredKey = key
        let verdict = center.hosts.knownHosts.verdict(address: host.address, port: host.port, key: key)
        self.verdict = verdict
        switch verdict {
        case .trusted:
            set(.hostKey, .pass, "\(key.type) matches the key saved on this iPhone")
            return true
        case .unknown:
            if center.launch.autoTrusts(key.fingerprint) {
                center.hosts.trust(key, for: host, address: host.address)
                self.verdict = .trusted
                set(.hostKey, .pass, "\(key.type) trusted at launch (fingerprint matched LOJO_SSH_TRUST_FP)")
                return true
            }
            set(.hostKey, .warn, "\(key.type) not saved yet. Check the fingerprint below, then trust it.")
            return false
        case .changed:
            set(.hostKey, .fail, "CHANGED: the host offered a different key than the one saved. Possible man-in-the-middle, or the host was reinstalled.")
            Haptics.error()
            return false
        }
    }

    private func set(_ kind: Kind, _ status: Status, _ detail: String = "", millis: Double? = nil) {
        guard let i = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[i].status = status
        steps[i].detail = detail
        steps[i].millis = millis
    }

    private func skip(from kind: Kind, _ detail: String) {
        guard let start = Kind.allCases.firstIndex(of: kind) else { return }
        for k in Kind.allCases[start...] { set(k, .skipped, detail) }
    }

    private func mask(_ address: String) -> String {
        AddressDisplay.text(address, redact: center.redact)
    }

    private func mask(_ range: IPv4Range) -> String {
        let text = range.description
        guard let slash = text.firstIndex(of: "/") else { return text }
        return mask(String(text[..<slash])) + text[slash...]
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var center: TerminalCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diag: HostDiagnostics

    init(host: SSHHost, center: TerminalCenter) {
        _diag = StateObject(wrappedValue: HostDiagnostics(host: host, center: center))
    }

    private var host: SSHHost { diag.host }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(diag.steps) { step in
                        StepRow(step: step)
                    }
                } header: {
                    Text("\(host.username)@\(AddressDisplay.text(host.address, redact: center.redact)):\(String(host.port))")
                        .textCase(nil)
                        .font(.footnote.monospaced())
                }
                if let key = diag.offeredKey {
                    hostKeySection(key)
                }
                if diag.authFailure != nil {
                    Section {
                        if let record = center.authorizeKey(for: host) {
                            AuthorizeKeyControls(record: record, host: host)
                        } else {
                            Text("There's no SSH key on this iPhone yet. Create one under Keys, then come back.")
                                .font(.subheadline)
                        }
                    } header: {
                        Text("Authorize this iPhone")
                    }
                }
                Section {
                    Button {
                        Task { await diag.run() }
                    } label: {
                        Label("Run again", systemImage: "arrow.clockwise")
                    }
                    .disabled(diag.running)
                }
            }
            .navigationTitle("Diagnose \(host.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await diag.run() }
        }
    }

    @ViewBuilder
    private func hostKeySection(_ key: HostKeyInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(key.type).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FingerprintText(fingerprint: key.fingerprint)
            }
            if case .changed(let previous)? = diag.verdict {
                ForEach(previous, id: \.self) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SAVED · \(entry.keyType)").font(.caption.weight(.semibold)).foregroundStyle(LojoTheme.danger)
                        FingerprintText(fingerprint: entry.fingerprint)
                    }
                }
                Text("Login was not attempted. If you know why the key changed, use Forget saved host key in the host's settings and run this again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if diag.verdict == .unknown {
                Text("On the host, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` must print the same fingerprint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await diag.trustOfferedKey() }
                } label: {
                    Label("Trust and test login", systemImage: "checkmark.shield")
                }
                .disabled(diag.running)
            }
        } header: {
            Text("Host key offered")
        }
    }
}

private struct StepRow: View {
    let step: HostDiagnostics.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(step.kind.title).font(.body.weight(.medium))
                    Spacer()
                    if let ms = step.millis {
                        Text(ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(step.kind == .banner ? .caption.monospaced() : .caption)
                        .foregroundStyle(step.status == .fail ? LojoTheme.danger : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        switch step.status {
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(LojoTheme.online)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LojoTheme.warning)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(LojoTheme.danger)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }
}

/// Public key with Copy / Share, plus the one-line command that adds it on the host.
struct AuthorizeKeyControls: View {
    let record: SSHKeyRecord
    /// nil: generic instructions (Keys screen).
    var host: SSHHost?
    @State private var copied: String?

    var body: some View {
        Text(record.publicKey)
            .font(.caption2.monospaced())
            .textSelection(.enabled)
            .lineLimit(4)
        Button {
            copy(AuthorizeCommand.text(publicKey: record.publicKey), as: "command")
        } label: {
            Label(copied == "command" ? "Copied" : "Copy authorize command", systemImage: copied == "command" ? "checkmark" : "terminal")
                .font(.body.weight(.semibold))
        }
        Button {
            copy(record.publicKey, as: "key")
        } label: {
            Label(copied == "key" ? "Copied" : "Copy public key", systemImage: copied == "key" ? "checkmark" : "doc.on.doc")
        }
        ShareLink(item: record.publicKey) {
            Label("Share public key", systemImage: "square.and.arrow.up")
        }
        Text(instructions)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var instructions: String {
        let how = "It creates ~/.ssh if needed, adds the key once, and sets the permissions sshd requires."
        guard let host else {
            return "Run the command on each device, logged in as the user this iPhone connects as. " + how
        }
        return "Run the command on \(host.label) logged in as \(host.username) (console, or SSH from a computer that already has access). " + how
    }

    private func copy(_ text: String, as which: String) {
        UIPasteboard.general.string = text
        copied = which
        Haptics.success()
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == which { copied = nil }
        }
    }
}
