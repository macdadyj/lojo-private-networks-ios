import SwiftUI

enum CheckState: Equatable {
    case pending, running, pass, warn, fail, skipped
}

struct CheckStep: Identifiable, Equatable {
    let id: String
    var title: String
    var state: CheckState = .pending
    var detail: String = ""
}

struct Verdict: Equatable {
    enum Tone { case good, caution, bad }

    let tone: Tone
    let icon: String
    let title: String
    let message: String
    let tips: [String]
}

@MainActor
final class ConnectionCheck: ObservableObject {
    @Published var steps: [CheckStep] = []
    @Published var verdict: Verdict?
    @Published var running = false
    @Published var finishedAt: Date?

    func run(store: NetworkStore) async {
        guard !running else { return }
        running = true
        verdict = nil
        steps = [
            CheckStep(id: "phone", title: "This phone's network"),
            CheckStep(id: "lan", title: ConnectionPath.lan.longTitle),
            CheckStep(id: "overlay", title: ConnectionPath.overlay.longTitle),
            CheckStep(id: "hub", title: "Cloud hub"),
            CheckStep(id: "devices", title: "Your devices"),
        ]

        if store.isDemo {
            await runDemo()
            return
        }

        update("phone", .running)
        let phone = PhoneInterfaces.current()
        update("phone", phone.hasWiFi || phone.cellularActive || phone.hasVPN ? .pass : .fail, phoneDetail(phone))

        update("lan", .running)
        update("overlay", .running)
        let results = await store.probeAll()
        let lan = results.first { $0.endpoint.path == .lan }
        let overlay = results.first { $0.endpoint.path == .overlay }
        apply(lan, to: "lan")
        apply(overlay, to: "overlay")

        let reached = [lan, overlay].compactMap { $0 }.first(where: \.reachable)
        if let net = reached?.network {
            update("hub", net.hub.connected ? .pass : .fail,
                   net.hub.connected ? "The site gateway is connected to the cloud hub." : "The site gateway is up but can't reach the cloud hub.")
            let c = net.devices
            update("devices", c.online > 0 ? .pass : .warn,
                   c.total == 0 ? "No devices have joined yet." : "\(c.online) online, \(c.offline) offline.")
        } else {
            update("hub", .skipped, "Skipped — the site gateway isn't reachable.")
            update("devices", .skipped, "Skipped — the site gateway isn't reachable.")
        }

        verdict = Self.verdict(phone: phone, lan: lan, overlay: overlay)
        switch verdict?.tone {
        case .good: Haptics.success()
        case .caution: Haptics.warning()
        case .bad: Haptics.error()
        case nil: break
        }
        finishedAt = Date()
        running = false
        await store.refresh(.pathChange)
    }

    private func runDemo() async {
        for id in ["phone", "lan", "overlay", "hub", "devices"] {
            update(id, .running)
            try? await Task.sleep(for: .milliseconds(260))
            switch id {
            case "phone": update(id, .pass, "Cellular data · VPN tunnel active")
            case "lan": update(id, .warn, "Not on site Wi‑Fi — expected while you're away.")
            case "overlay": update(id, .pass, "Site gateway answered in 38 ms.")
            case "hub": update(id, .pass, "The site gateway is connected to the cloud hub.")
            default: update(id, .pass, "5 online, 1 offline.")
            }
        }
        verdict = Verdict(
            tone: .good, icon: "lock.shield.fill",
            title: "Connected through your private overlay",
            message: "You're away from the site and your LOJO VPN profile is carrying traffic over the encrypted overlay. Your devices stay off the public internet.",
            tips: []
        )
        Haptics.success()
        finishedAt = Date()
        running = false
    }

    private func update(_ id: String, _ state: CheckState, _ detail: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        if let detail { steps[i].detail = detail }
    }

    private func apply(_ result: ProbeResult?, to id: String) {
        guard let result else {
            update(id, .skipped, "No address configured.")
            return
        }
        if result.reachable {
            update(id, .pass, "Site gateway answered in \(result.latencyMs ?? 0) ms.")
        } else {
            let why = result.error?.errorDescription ?? "No answer."
            update(id, id == "lan" ? .warn : .fail, why)
        }
    }

    private func phoneDetail(_ p: PhoneInterfaces) -> String {
        var parts: [String] = []
        if let ip = p.wifiIPv4 { parts.append("Wi‑Fi \(ip)") }
        if p.cellularActive { parts.append("Cellular data") }
        parts.append(p.hasVPN ? "VPN tunnel active" : "No VPN tunnel")
        if !p.hasWiFi && !p.cellularActive && !p.hasVPN { return "No Wi‑Fi, cellular or VPN connection." }
        return parts.joined(separator: " · ")
    }

    static func verdict(phone: PhoneInterfaces, lan: ProbeResult?, overlay: ProbeResult?) -> Verdict {
        let viaLAN = lan?.reachable == true
        let viaOverlay = overlay?.reachable == true
        let net = (viaLAN ? lan : overlay)?.network

        if let net, !net.hub.connected {
            return Verdict(
                tone: .caution, icon: "exclamationmark.triangle.fill",
                title: "Gateway reachable, cloud hub offline",
                message: "Your phone reaches the site gateway \(viaLAN ? "on site Wi‑Fi" : "through the private overlay"), but the gateway has lost its link to the cloud hub. Device status may be out of date and cameras and controls are paused.",
                tips: [
                    "Wait a minute — the gateway reconnects on its own.",
                    "If it stays offline, check the site's internet connection.",
                ]
            )
        }
        if viaLAN {
            var tips: [String] = []
            if viaOverlay { tips.append("The private overlay also works, so you'll stay connected when you leave.") }
            else if !phone.hasVPN { tips.append("Before you leave the site, turn on your LOJO VPN profile to keep access.") }
            return Verdict(
                tone: .good, icon: "wifi",
                title: "You're on site Wi‑Fi",
                message: "Your phone reaches the site gateway directly on the local network. Traffic stays inside your site — nothing goes over the internet.",
                tips: tips
            )
        }
        if viaOverlay {
            return Verdict(
                tone: .good, icon: "lock.shield.fill",
                title: "Connected through your private overlay",
                message: "You're not on site Wi‑Fi, and your LOJO VPN profile is carrying traffic over the encrypted private overlay. Your devices stay off the public internet.",
                tips: []
            )
        }

        if case .localNetworkDenied? = lan?.error, !viaOverlay {
            return Verdict(
                tone: .bad, icon: "hand.raised.fill",
                title: "Local Network access is off",
                message: "iOS is blocking LOJO Networks from talking to devices on your Wi‑Fi, so the site gateway can't be reached even when you're on site.",
                tips: [
                    "Open Settings › Privacy & Security › Local Network and turn on LOJO Networks.",
                    "Away from the site? Your LOJO VPN profile works without this permission.",
                ]
            )
        }

        var tips: [String] = []
        let title: String
        let message: String
        if !phone.hasWiFi && !phone.cellularActive && !phone.hasVPN {
            title = "This phone is offline"
            message = "There's no Wi‑Fi or cellular connection, so nothing can reach your network."
            tips = ["Turn off Airplane Mode or join a Wi‑Fi network, then run the check again."]
        } else if phone.hasVPN {
            title = "VPN is on, but your network didn't answer"
            message = "A VPN tunnel is active on this phone, but the site gateway didn't respond through it."
            tips = [
                "Make sure the VPN profile you connected is your LOJO profile for this network.",
                "The site gateway may be powered off or offline — check it at the site.",
            ]
        } else {
            title = "Can't reach your private network"
            message = phone.hasWiFi
                ? "You're on Wi‑Fi, but it isn't your site's network (or the site gateway is off), and the private overlay isn't connected."
                : "You're on cellular data without the private overlay, so your devices can't be reached."
            tips = ["Away from the site? Turn on your LOJO VPN profile, then run the check again."]
            if phone.hasWiFi { tips.append("At the site? Join the site's Wi‑Fi network.") }
        }
        return Verdict(tone: .bad, icon: "wifi.slash", title: title, message: message, tips: tips)
    }
}

struct ConnectionCheckView: View {
    @EnvironmentObject private var store: NetworkStore
    @StateObject private var check = ConnectionCheck()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                verdictCard
                stepsCard
                Button {
                    Haptics.light()
                    Task { await check.run(store: store) }
                } label: {
                    Label(check.running ? "Checking…" : "Run check again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(check.running)
                explainer
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Connection")
        .toolbar {
            if store.isDemo {
                ToolbarItem(placement: .topBarLeading) { DemoBadge() }
            }
        }
        .task { await check.run(store: store) }
    }

    @ViewBuilder
    private var verdictCard: some View {
        if let v = check.verdict {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(tint(v.tone).opacity(0.16))
                        Image(systemName: v.icon)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(tint(v.tone))
                    }
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                    Text(v.title)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(v.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if !v.tips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(v.tips, id: \.self) { tip in
                            Label {
                                Text(tip).font(.subheadline)
                            } icon: {
                                Image(systemName: "arrow.right.circle.fill").foregroundStyle(tint(v.tone))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                if let at = check.finishedAt {
                    Text("Checked \(RelativeTime.clock(at))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .card()
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text("Checking how this phone reaches your network…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .card()
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(check.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    stepIcon(step.state)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.title): \(stateWord(step.state)). \(step.detail)")
                if index < check.steps.count - 1 {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .card(padding: 14)
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How your phone reaches your devices")
                .font(.subheadline.weight(.semibold))
            Text("At the site, the app talks to your site gateway directly over Wi‑Fi. Away from the site, your LOJO VPN profile joins this phone to your private overlay so the same gateway answers — encrypted end to end. Your cameras and controls are never published to the public internet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func stepIcon(_ state: CheckState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(LojoTheme.online)
        case .warn: Image(systemName: "minus.circle.fill").foregroundStyle(LojoTheme.warning)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(LojoTheme.danger)
        case .skipped: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        }
    }

    private func stateWord(_ state: CheckState) -> String {
        switch state {
        case .pending: return "waiting"
        case .running: return "checking"
        case .pass: return "OK"
        case .warn: return "not available"
        case .fail: return "failed"
        case .skipped: return "skipped"
        }
    }

    private func tint(_ tone: Verdict.Tone) -> Color {
        switch tone {
        case .good: return LojoTheme.online
        case .caution: return LojoTheme.warning
        case .bad: return LojoTheme.danger
        }
    }
}
