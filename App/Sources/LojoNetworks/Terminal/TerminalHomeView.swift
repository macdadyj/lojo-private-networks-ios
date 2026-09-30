import LojoSSH
import SwiftUI

enum TerminalRoute: Hashable {
    case keys
}

struct TerminalHomeView: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var center: TerminalCenter
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var keys: SSHKeyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [TerminalRoute] = []
    @State private var editing: HostDraft?
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if center.vpnAddress == nil {
                    vpnBanner
                }
                if !center.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(center.sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                }
                if keys.keys.isEmpty {
                    keySetupPrompt
                }
                ForEach(hosts.groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.hosts) { host in
                            HostRow(host: host, onEdit: { editing = HostDraft(host: host, isNew: false) })
                        }
                    }
                }
                GatewayDevicesSection()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: TerminalRoute.keys) {
                        Label("Keys", systemImage: "key.horizontal")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .accessibilityLabel("Terminal settings")
                    Button {
                        editing = HostDraft(host: SSHHost(label: "", address: "", username: "jon"), isNew: true)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add host")
                }
            }
            .navigationDestination(for: TerminalRoute.self) { route in
                switch route {
                case .keys: KeysView()
                }
            }
            .refreshable { await center.refreshDirectory() }
        }
        .sheet(item: $editing) { draft in
            HostEditorView(draft: draft)
                .environmentObject(center)
                .environmentObject(hosts)
                .environmentObject(keys)
        }
        .sheet(isPresented: $showSettings) {
            TerminalSettingsView()
                .environmentObject(center)
        }
        .fullScreenCover(isPresented: $center.showingSession) {
            SessionScreen()
                .environmentObject(center)
                .environmentObject(hosts)
                .environmentObject(keys)
        }
        .onAppear(perform: appear)
        .onChange(of: scenePhase) { _, phase in
            center.sceneChanged(active: phase == .active)
        }
    }

    private var vpnBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("LOJO VPN is off", systemImage: "lock.slash")
                    .font(.headline)
                    .foregroundStyle(LojoTheme.warning)
                Text("SSH only runs over your private LOJO overlay. Turn on your LOJO profile in OpenVPN Connect, then come back here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Run connection check") { router.tab = .check }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.vertical, 4)
        }
    }

    private var keySetupPrompt: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("No SSH key on this phone yet", systemImage: "key.horizontal")
                    .font(.headline)
                Text("Create a key in the Secure Enclave. It never leaves this iPhone. Then add its public key to each device's authorized_keys.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Set up a key") { path = [.keys] }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.vertical, 4)
        }
    }

    private func appear() {
        hosts.seedGateway(overlayGatewayURL: store.launch.overlayOverride ?? store.overlayAddress, port: center.launch.gatewayPort)
        guard !center.launchApplied else { return }
        center.launchApplied = true
        let launch = center.launch
        if launch.ensureKey, keys.keys.isEmpty {
            if keys.secureEnclaveAvailable {
                _ = try? keys.generateSecureEnclave(label: "LOJO iPhone")
            } else {
                _ = try? keys.generateEd25519(label: "LOJO iPhone")
            }
        }
        switch launch.screen {
        case .keys: path = [.keys]
        case .settings: showSettings = true
        case .hosts, .session, nil: break
        }
        if let wanted = launch.connect?.lowercased() {
            let match = hosts.hosts.first {
                $0.label.lowercased() == wanted || ($0.isGateway && wanted == "gateway")
            }
            if let match { center.open(match) }
        }
    }
}

struct HostDraft: Identifiable {
    var host: SSHHost
    var isNew: Bool
    var id: UUID { host.id }
}

private struct SessionRow: View {
    @EnvironmentObject private var center: TerminalCenter
    @ObservedObject var session: TerminalSession

    var body: some View {
        Button {
            center.show(session)
        } label: {
            HStack(spacing: 12) {
                Circle().fill(session.phase.tint).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.host.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(session.phase.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .swipeActions {
            Button("Close", role: .destructive) { center.close(session) }
        }
    }
}

private struct HostRow: View {
    @EnvironmentObject private var center: TerminalCenter
    @EnvironmentObject private var hosts: HostStore
    let host: SSHHost
    let onEdit: () -> Void

    private var trusted: Bool { !hosts.savedHostKeys(for: host).isEmpty }

    var body: some View {
        Button {
            center.open(host)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: host.isGateway ? "server.rack" : "terminal")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(host.isGateway ? LojoTheme.accentDeep : LojoTheme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text("\(host.username)@\(AddressDisplay.text(host.address, redact: center.redact))\(host.port == 22 ? "" : ":\(host.port)")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if trusted {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(LojoTheme.online)
                        .accessibilityLabel("Host key saved")
                }
            }
        }
        .disabled(center.vpnAddress == nil)
        .swipeActions {
            Button("Edit", action: onEdit).tint(LojoTheme.accentDeep)
        }
        .contextMenu {
            Button("Connect", systemImage: "terminal") { center.open(host) }
            Button("Edit", systemImage: "pencil", action: onEdit)
        }
    }
}

private struct GatewayDevicesSection: View {
    @EnvironmentObject private var center: TerminalCenter
    @EnvironmentObject private var hosts: HostStore

    var body: some View {
        Section {
            switch center.directoryState {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking the gateway…").foregroundStyle(.secondary)
                }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.warning)
            case .idle:
                EmptyView()
            }
            if let devices = hosts.directory?.devices, !devices.isEmpty {
                ForEach(devices) { entry in
                    DirectoryRow(entry: entry)
                }
            } else if center.directoryState == .idle {
                Text("Pull the list of LOJO devices from the site gateway over SSH. You can save any of them as a host with one tap.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Gateway devices")
                Spacer()
                Button {
                    Task { await center.refreshDirectory() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .disabled(center.directoryState == .loading)
            }
        } footer: {
            if let generated = hosts.directory?.generatedAt,
               let date = ISO8601DateFormatter().date(from: generated) {
                Text("Updated \(RelativeTime.text(date)). Only devices on the overlay or LOJO-routed subnets are listed.")
            }
        }
    }
}

private struct DirectoryRow: View {
    @EnvironmentObject private var center: TerminalCenter
    @EnvironmentObject private var hosts: HostStore
    let entry: DirectoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(entry.online ? LojoTheme.online : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body.weight(.medium))
                Text("\(AddressDisplay.text(entry.address, redact: center.redact)) · \(entry.group) · \(entry.sshOpen ? "SSH open" : "no SSH")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hosts.isSaved(entry) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LojoTheme.online)
                    .accessibilityLabel("Saved")
            } else {
                Button("Save") {
                    hosts.save(entry)
                    Haptics.success()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!entry.sshOpen)
            }
        }
    }
}

extension TerminalSession.Phase {
    var summary: String {
        switch self {
        case .connecting: return "Connecting…"
        case .awaitingHostKey: return "Check the host key"
        case .awaitingPassword: return "Password needed"
        case .connected: return "Connected"
        case .waitingForVPN: return "Waiting for LOJO VPN…"
        case .reconnecting(let attempt, let delay): return "Reconnecting in \(delay) s (try \(attempt))"
        case .hostKeyChanged: return "HOST KEY CHANGED"
        case .ended(let text): return text
        case .failed(let text): return text
        }
    }

    var tint: Color {
        switch self {
        case .connected: return LojoTheme.online
        case .connecting, .awaitingHostKey, .awaitingPassword, .reconnecting, .waitingForVPN: return LojoTheme.warning
        case .hostKeyChanged, .failed: return LojoTheme.danger
        case .ended: return .secondary
        }
    }
}
