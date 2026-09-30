import SwiftUI
import UIKit

extension GatewayEndpoint.Protection {
    var label: String {
        switch self {
        case .tls: return "Encrypted · pinned"
        case .vpnOnly: return "Legacy HTTP over VPN"
        case .none: return "Unencrypted (legacy HTTP)"
        }
    }

    var systemImage: String {
        switch self {
        case .tls: return "lock.fill"
        case .vpnOnly: return "lock.trianglebadge.exclamationmark"
        case .none: return "lock.open.fill"
        }
    }

    var tint: Color {
        switch self {
        case .tls: return LojoTheme.online
        case .vpnOnly, .none: return LojoTheme.warning
        }
    }

    var explanation: String {
        switch self {
        case .tls:
            return "HTTPS to your site gateway, checked against the certificate authority pinned on this phone."
        case .vpnOnly:
            return "Plain HTTP inside the VPN tunnel. The VPN encrypts it in transit, but the gateway's identity isn't checked. Used only when HTTPS doesn't answer."
        case .none:
            return "Plain HTTP on site Wi‑Fi. Anyone on that Wi‑Fi can read it. Pair this phone with the gateway to encrypt it."
        }
    }
}

struct ProtectionPill: View {
    let protection: GatewayEndpoint.Protection

    var body: some View {
        StatusPill(text: protection.label, systemImage: protection.systemImage, tint: protection.tint)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Connection: \(protection.label)")
    }
}

/// Confirms a scanned or pasted pairing code and pins the gateway's CA.
struct PairingView: View {
    let offer: PairingOffer
    var inSheet = false
    @EnvironmentObject private var store: NetworkStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(LojoTheme.accent)
                    Text("Pair with your site gateway")
                        .font(.title2.weight(.bold))
                    Text("This phone will trust only the certificate authority below. After pairing, the app talks to your gateway over HTTPS, so traffic on site Wi‑Fi is encrypted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }

            Section("Gateway") {
                LabeledContent("Network", value: offer.name)
                if let lan = offer.lan { addressRow("Site Wi‑Fi", lan) }
                if let ov = offer.overlay { addressRow("Overlay", ov) }
            }

            Section {
                Text(SiteCA.fingerprintLines(offer.caSHA256, perLine: 8))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Site CA fingerprint (SHA-256)")
            } footer: {
                Text("It should match the fingerprint printed by the pairing command on the gateway. The phone checks it against the gateway's certificate before saving anything.")
            }

            if let current = store.siteCA, current.sha256 != offer.caSHA256 {
                Section {
                    Label("This replaces the current pairing (\(current.shortFingerprint)).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LojoTheme.warning)
                        .font(.subheadline)
                }
            }

            Section {
                Button {
                    Task {
                        if await store.pair(offer), !inSheet { dismiss() }
                    }
                } label: {
                    if store.pairingState == .working {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Pairing…")
                        }
                    } else {
                        Label("Pair", systemImage: "checkmark.shield.fill")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.pairingState == .working)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if case .failed(let message) = store.pairingState {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Pairing needs this phone to reach the gateway: be on site Wi‑Fi, or connected to your LOJO VPN.")
            }
        }
        .navigationTitle("Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.dismissPairing() }
                }
            }
        }
        .onDisappear {
            if !inSheet, store.pairingState != .working { store.dismissPairing() }
        }
    }

    private func addressRow(_ label: String, _ url: URL) -> some View {
        LabeledContent(label) {
            Text(url.absoluteString)
                .font(.footnote.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Settings › Security: pairing status, fingerprint, pairing code entry and the legacy fallback.
struct SecuritySection: View {
    /// Set to a pasted offer; the owning NavigationStack pushes `PairingView` for it.
    @Binding var pasted: PairingOffer?
    /// Setup shows only the status and pairing entry; Settings has the full controls.
    var compact = false
    @EnvironmentObject private var store: NetworkStore
    @State private var pasteProblem: String?
    @State private var confirmForget = false

    var body: some View {
        Section {
            if let ca = store.siteCA {
                LabeledContent("Status") {
                    ProtectionPill(protection: .tls)
                }
                if compact {
                    LabeledContent("Site CA") {
                        Text(ca.shortFingerprint).font(.callout.monospaced())
                    }
                } else {
                    pairedDetails(ca)
                }
            } else {
                LabeledContent("Status") {
                    ProtectionPill(protection: .none)
                }
            }
            if !(compact && store.isPaired) {
                Button {
                    pastePairingCode()
                } label: {
                    Label(store.isPaired ? "Pair again from pasted code" : "Paste pairing code", systemImage: "doc.on.clipboard")
                }
            }
            if let pasteProblem {
                Text(pasteProblem)
                    .font(.caption)
                    .foregroundStyle(LojoTheme.danger)
            }
            if store.isPaired && !compact {
                Button("Forget pairing", role: .destructive) { confirmForget = true }
            }
        } header: {
            Text("Security")
        } footer: {
            Text(store.isPaired && compact
                 ? "Paired: the app uses HTTPS checked against this site's certificate. Manage it in Settings › Security."
                 : store.isPaired
                 ? "HTTPS is used on site Wi‑Fi and the overlay. Legacy HTTP over VPN is only tried on the overlay, where the VPN still encrypts it; it's never used on site Wi‑Fi once paired."
                 : "Not paired: the app uses plain HTTP, which anyone on site Wi‑Fi can read. To encrypt it, scan the gateway's pairing QR code with the iPhone Camera app, or copy the lojo://pair code and paste it here.")
        }
        .disabled(store.isDemo)
        .confirmationDialog("Forget the pinned certificate?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget pairing", role: .destructive) { store.forgetPairing() }
        } message: {
            Text("The app will fall back to unencrypted HTTP until you pair again.")
        }
    }

    @ViewBuilder
    private func pairedDetails(_ ca: SiteCA) -> some View {
        LabeledContent("Site", value: store.network?.site?.name ?? store.networkName)
        VStack(alignment: .leading, spacing: 4) {
            Text("Site CA fingerprint (SHA-256)").font(.subheadline)
            Text(SiteCA.fingerprintLines(ca.sha256, perLine: 16))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let current = store.protection, current != .tls {
            Label("Right now: \(current.label). \(current.explanation)", systemImage: current.systemImage)
                .font(.footnote)
                .foregroundStyle(LojoTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        Toggle(isOn: $store.legacyOverVPN) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Legacy HTTP over VPN")
                Text("Fallback when HTTPS doesn't answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: store.legacyOverVPN) {
            Haptics.selection()
            Task { await store.refresh(.user) }
        }
    }

    private func pastePairingCode() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            pasteProblem = "The clipboard is empty. Copy the lojo://pair code first."
            return
        }
        guard let offer = PairingOffer(code: text) else {
            pasteProblem = "That isn't a LOJO pairing code (it should start with lojo://pair)."
            Haptics.warning()
            return
        }
        pasteProblem = nil
        pasted = offer
    }
}
