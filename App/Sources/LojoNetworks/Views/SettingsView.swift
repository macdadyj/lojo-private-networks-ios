import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lojo.onboarded") private var onboarded = true
    @AppStorage("lojo.appearance") private var appearanceRaw = Appearance.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $store.isDemo) {
                        Label("Demo network", systemImage: "sparkles")
                    }
                    .onChange(of: store.isDemo) { Haptics.selection() }
                } footer: {
                    Text(store.isDemo
                         ? "Showing Juniper Mesa Ranch, a sample network. Captures and controls are simulated."
                         : "Turn on to explore the app with sample devices. Your real network is untouched.")
                }

                Section("Your network") {
                    TextField("Network name", text: $store.networkName)
                        .textInputAutocapitalization(.words)
                        .disabled(store.isDemo)
                    LabeledContent("Status", value: statusText)
                    if let net = store.network, !store.isDemo {
                        LabeledContent("Site gateway", value: net.gateway.name)
                        LabeledContent("Cloud hub", value: net.hub.connected ? "Connected" : "Offline")
                    }
                }

                Section {
                    AddressRow(path: .lan, text: $store.lanAddress, active: store.link.path == .lan)
                    AddressRow(path: .overlay, text: $store.overlayAddress, active: store.link.path == .overlay)
                    Button("Reset to defaults") {
                        store.resetAddresses()
                        Task { await store.refresh(.user) }
                    }
                    .disabled(store.isDemo)
                } header: {
                    Text("Gateway addresses")
                } footer: {
                    Text("Enter an IP address or host name; the port defaults to 8801. The app tries both paths at once and uses site Wi‑Fi when it answers, otherwise the private overlay. Overlay addresses only work while your LOJO VPN profile is connected.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(Appearance.allCases) { a in
                            Text(a.title).tag(a.rawValue)
                        }
                    }
                }

                Section {
                    Button("Connection setup") {
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            router.showSetup = true
                        }
                    }
                    .disabled(store.isDemo)
                    Button("Show welcome screens again") {
                        dismiss()
                        onboarded = false
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } footer: {
                    Text("LOJO Private Networks · your devices, your network, your control.\nQuestions: team@lojo.engineering")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        switch store.link {
        case .connecting: return "Connecting…"
        case .connected(let ep): return "Connected · \(ep.path.title)"
        case .unreachable: return "Not reachable"
        case .demo: return "Demo"
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// One editable gateway address with validation and a one-tap reachability test.
struct AddressRow: View {
    let path: ConnectionPath
    @Binding var text: String
    let active: Bool
    /// Changing this value runs the test without a tap (used by Setup).
    var autoTest: Int = 0
    @EnvironmentObject private var store: NetworkStore
    @State private var testing = false
    @State private var result: PathReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(path.longTitle, systemImage: path.systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if active {
                    Text("IN USE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(LojoTheme.online)
                }
            }
            HStack(spacing: 8) {
                TextField(path == .lan ? "IP address or host name" : "Overlay IP or host name", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .submitLabel(.done)
                    .onSubmit { Task { await store.refresh(.user) } }
                    .onChange(of: text) { result = nil }
                Button {
                    Task { await test() }
                } label: {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test").font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(testing || GatewayAddress.normalize(text) == nil)
            }
            if let problem = GatewayAddress.validationMessage(text) {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(LojoTheme.danger)
            } else if let result {
                let expected = !result.reachable && vpnOffForOverlay
                Label(summary(result), systemImage: result.reachable ? "checkmark.circle.fill"
                      : expected ? "minus.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.reachable ? LojoTheme.online : expected ? LojoTheme.warning : LojoTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .disabled(store.isDemo)
        .task(id: autoTest) {
            if autoTest > 0 { await test() }
        }
    }

    private func test() async {
        guard let url = GatewayAddress.normalize(text) else { return }
        testing = true
        result = await PathDiagnostics.run(GatewayEndpoint(path: path, baseURL: url))
        testing = false
        if result?.reachable == true { Haptics.success() } else { Haptics.warning() }
    }

    private func summary(_ r: PathReport) -> String {
        if let net = r.probe?.network {
            return "\(net.gateway.name) answered in \(r.probe?.latencyMs ?? 0) ms."
        }
        let code = r.probe?.error?.technical ?? "No answer"
        if vpnOffForOverlay {
            return "No VPN connected, so this path can't answer yet. That's expected until you connect your LOJO VPN. (\(code))"
        }
        let meaning = r.probe?.error?.errorDescription ?? ""
        return "\(code) — \(meaning)"
    }

    private var vpnOffForOverlay: Bool {
        path == .overlay && !PhoneInterfaces.current().hasVPN
    }
}
