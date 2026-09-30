import SwiftUI

/// First-run "Connect my network": name the network and watch both paths test live, with the one
/// thing to do next for each (join site Wi‑Fi, or connect the LOJO VPN profile).
struct SetupView: View {
    @EnvironmentObject private var store: NetworkStore
    @Environment(\.dismiss) private var dismiss
    @State private var phone = PhoneInterfaces.current()
    @State private var round = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect your network")
                            .font(.title2.weight(.bold))
                        Text("Your phone reaches your site gateway in one of two private ways. The app tests both and always picks the one that works.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Network name", text: $store.networkName)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    AddressRow(path: .lan, text: $store.lanAddress, active: store.link.path == .lan, autoTest: round)
                } header: {
                    Text("At the site")
                } footer: {
                    Text(phone.hasWiFi
                         ? "Join your site's Wi‑Fi. If iOS asks to find devices on your local network, choose Allow."
                         : "This phone isn't on Wi‑Fi. At the site, join your site's Wi‑Fi network.")
                }

                Section {
                    AddressRow(path: .overlay, text: $store.overlayAddress, active: store.link.path == .overlay, autoTest: round)
                } header: {
                    Text("Away from the site")
                } footer: {
                    Text(phone.hasVPN
                         ? "A VPN tunnel is connected (\(phone.vpnSummary ?? "utun")). If this test fails, check that it's your LOJO profile."
                         : "Open your VPN app (for example OpenVPN Connect), import the LOJO profile you were sent, and connect it. Then tap Test again.")
                }

                Section {
                    Button {
                        phone = PhoneInterfaces.current()
                        round += 1
                        Task { await store.refresh(.user) }
                    } label: {
                        Label("Test both again", systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text("You can change these later in Settings. Addresses are private; they never work from the public internet.")
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.success()
                        dismiss()
                    }
                }
            }
            .onAppear { round += 1 }
        }
    }
}
