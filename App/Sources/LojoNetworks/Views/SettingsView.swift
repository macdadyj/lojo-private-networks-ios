import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: NetworkStore
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
                    LabeledContent("Site Wi‑Fi") {
                        TextField("http://…", text: $store.lanAddress)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                    }
                    LabeledContent("Private overlay") {
                        TextField("http://…", text: $store.overlayAddress)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                    }
                    Button("Reset to defaults") {
                        store.resetAddresses()
                        Task { await store.refresh(.user) }
                    }
                } header: {
                    Text("Gateway addresses")
                } footer: {
                    Text("The app tries site Wi‑Fi first, then the private overlay. These are private addresses; they only work on your site network or with your LOJO VPN profile on.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(Appearance.allCases) { a in
                            Text(a.title).tag(a.rawValue)
                        }
                    }
                }

                Section {
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
