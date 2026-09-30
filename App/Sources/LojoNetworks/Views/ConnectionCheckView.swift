import SwiftUI
import UIKit

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
    @Published var phoneLines: [DiagLine] = []
    @Published var reports: [PathReport] = []

    func run(store: NetworkStore) async {
        guard !running else { return }
        running = true
        verdict = nil
        reports = []
        steps = [
            CheckStep(id: "phone", title: "This phone's network"),
            CheckStep(id: "lan", title: ConnectionPath.lan.longTitle),
            CheckStep(id: "overlay", title: ConnectionPath.overlay.longTitle),
            CheckStep(id: "security", title: "Encryption"),
            CheckStep(id: "hub", title: "Cloud hub"),
            CheckStep(id: "devices", title: "Your devices"),
        ]

        if store.isDemo {
            await runDemo()
            return
        }

        update("phone", .running)
        let phone = PhoneInterfaces.current()
        phoneLines = PathDiagnostics.phoneSummary(phone)
        update("phone", phone.hasWiFi || phone.cellularActive || phone.hasVPN ? .pass : .fail, phoneDetail(phone))

        update("lan", .running)
        update("overlay", .running)
        let eps = store.endpoints()
        let anchor = store.siteCA
        let found = await withTaskGroup(of: (Int, PathReport).self) { group in
            for (i, ep) in eps.enumerated() { group.addTask { (i, await PathDiagnostics.run(ep, anchor: anchor)) } }
            var out: [(Int, PathReport)] = []
            for await r in group { out.append(r) }
            return out
        }
        reports = found.sorted { $0.0 < $1.0 }.map(\.1)
        let lan = reports.first { $0.path == .lan }
        let overlay = reports.first { $0.path == .overlay }
        let legacy = reports.first { $0.path == .overlay && $0.protection == .vpnOnly && $0.id != overlay?.id }
        apply(lan, to: "lan")
        apply(overlay, to: "overlay", vpnOff: !phone.hasVPN, legacy: legacy)
        applySecurity(anchor: anchor)

        let reached = reports.first(where: \.reachable)
        if let net = reached?.probe?.network {
            update("hub", net.hub.connected ? .pass : .fail,
                   net.hub.connected ? "The site gateway is connected to the cloud hub." : "The site gateway is up but can't reach the cloud hub.")
            let c = net.devices
            update("devices", c.online > 0 ? .pass : .warn,
                   c.total == 0 ? "No devices have joined yet." : "\(c.online) online, \(c.offline) offline.")
        } else {
            update("hub", .skipped, "Skipped — the site gateway isn't reachable.")
            update("devices", .skipped, "Skipped — the site gateway isn't reachable.")
        }

        verdict = Self.verdict(phone: phone, lan: lan, overlay: overlay, legacy: legacy, paired: store.isPaired)
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

    /// Plain-text version of everything on screen, for pasting into a support message.
    func reportText(store: NetworkStore) -> String {
        var out = ["LOJO Networks connection check — \(finishedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "running")"]
        if let v = verdict { out.append("Result: \(v.title)") }
        out.append("")
        out.append("Phone")
        for l in phoneLines { out.append("  \(l.label): \(l.value)") }
        out.append("  Pinned site CA: \(store.siteCA?.fullFingerprint ?? "not paired")")
        for r in reports {
            out.append("")
            out.append("\(r.title) — \(r.reachable ? "OK" : "FAILED") (\(r.totalMs) ms)")
            for l in r.lines { out.append("  \(l.label): \(l.value)") }
        }
        out.append("")
        out.append("App \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · iOS \(UIDevice.current.systemVersion)")
        return out.joined(separator: "\n")
    }

    private func runDemo() async {
        phoneLines = [
            DiagLine(label: "Wi‑Fi", value: "Not connected", status: .skip),
            DiagLine(label: "Cellular", value: "Active", status: .ok),
            DiagLine(label: "VPN tunnel", value: "utun4 100.96.2.41", status: .ok),
        ]
        for id in ["phone", "lan", "overlay", "security", "hub", "devices"] {
            update(id, .running)
            try? await Task.sleep(for: .milliseconds(260))
            switch id {
            case "phone": update(id, .pass, "Cellular data · VPN tunnel active")
            case "lan": update(id, .warn, "Not on site Wi‑Fi — expected while you're away.")
            case "overlay": update(id, .pass, "Site gateway answered in 41 ms over HTTPS.")
            case "security": update(id, .pass, "HTTPS · pinned site CA 3F:A1:07:5C … 9D:21:E4 · TLS 1.3")
            case "hub": update(id, .pass, "The site gateway is connected to the cloud hub.")
            default: update(id, .pass, "5 online, 1 offline.")
            }
        }
        let pin = DiagLine(label: "Pin", value: "Site CA 3F:A1:07:5C … 9D:21:E4 (Keychain)", status: .ok)
        let scheme = DiagLine(label: "Scheme", value: "HTTPS (TLS, pinned site CA)", status: .info)
        reports = [
            PathReport(path: .lan, address: "https://192.168.20.2:8443", lines: [
                DiagLine(label: "Address", value: "https://192.168.20.2:8443", status: .info),
                DiagLine(label: "Type", value: GatewayAddress.HostClass.privateLAN.title, status: .info),
                scheme, pin,
                DiagLine(label: "DNS", value: "Not needed (IP address)", status: .skip),
                DiagLine(label: "TCP 8443", value: "No TCP answer (timed out) after 5002 ms", status: .fail),
                DiagLine(label: "TLS", value: "Not attempted (no TCP connection)", status: .skip),
                DiagLine(label: "HTTPS", value: "NSURLErrorTimedOut (-1001) after 5003 ms", status: .fail),
                DiagLine(label: "Meaning", value: TransportFailure(code: -1001).meaning, status: .info),
            ], probe: nil, tcpOK: false, totalMs: 10_010, protection: .tls),
            PathReport(path: .overlay, address: "https://100.96.8.2:8443", lines: [
                DiagLine(label: "Address", value: "https://100.96.8.2:8443", status: .info),
                DiagLine(label: "Type", value: GatewayAddress.HostClass.overlay.title, status: .info),
                scheme, pin,
                DiagLine(label: "DNS", value: "Not needed (IP address)", status: .skip),
                DiagLine(label: "TCP 8443", value: "Connected in 38 ms via utun4 (VPN tunnel) from 100.96.2.41", status: .ok),
                DiagLine(label: "TLS", value: "TLS 1.3 · chain verified to site CA · cert until Nov 1, 2027", status: .ok),
                DiagLine(label: "HTTPS", value: "200 OK in 41 ms", status: .ok),
                DiagLine(label: "Gateway", value: "mesa-gateway · hub connected · arrived via overlay as https", status: .ok),
            ], probe: nil, tcpOK: true, totalMs: 84, protection: .tls),
        ]
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

    private func apply(_ report: PathReport?, to id: String, vpnOff: Bool = false, legacy: PathReport? = nil) {
        guard let report else {
            update(id, .skipped, "No address configured.")
            return
        }
        let over = report.protection == .tls ? " over HTTPS" : " over legacy HTTP"
        if report.reachable {
            update(id, .pass, "Site gateway answered in \(report.probe?.latencyMs ?? 0) ms\(over).")
        } else {
            let tag = report.probe?.error?.technical ?? "No answer"
            if vpnOff {
                update(id, .warn, "LOJO VPN not connected — \(tag)")
            } else if let legacy, legacy.reachable {
                update(id, .warn, "HTTPS failed (\(tag)); legacy HTTP over VPN answered in \(legacy.probe?.latencyMs ?? 0) ms.")
            } else {
                update(id, id == "lan" ? .warn : .fail, tag)
            }
        }
    }

    private func applySecurity(anchor: SiteCA?) {
        let paired = anchor != nil
        let secure = reports.filter { $0.protection == .tls }
        if let ok = secure.first(where: \.reachable) {
            let version = ok.probe?.tls?.version ?? "TLS"
            update("security", .pass, "HTTPS · pinned site CA \(anchor?.shortFingerprint ?? "") · \(version)")
            return
        }
        if let tls = secure.lazy.compactMap({ $0.probe?.error?.tlsFailure }).first {
            update("security", .fail, "\(tls.technical) — \(tls.meaning)")
            return
        }
        if let legacy = reports.first(where: { $0.reachable && $0.protection == .vpnOnly }) {
            update("security", .warn, paired
                   ? "Legacy HTTP over VPN (\(legacy.address)) — encrypted by the VPN only; HTTPS didn't answer."
                   : "Legacy HTTP over VPN — encrypted by the VPN only. Pair this phone for HTTPS.")
            return
        }
        if reports.contains(where: \.reachable) {
            update("security", .warn, "Unencrypted HTTP on site Wi‑Fi. Pair this phone with the gateway (Settings › Security) to encrypt it.")
            return
        }
        update("security", .skipped, paired ? "Skipped — the site gateway isn't reachable." : "Not paired · skipped — the site gateway isn't reachable.")
    }

    private func phoneDetail(_ p: PhoneInterfaces) -> String {
        var parts: [String] = []
        if p.hasWiFi { parts.append("Wi‑Fi") }
        if p.cellularActive { parts.append("Cellular data") }
        parts.append(p.hasVPN ? "VPN tunnel active" : "No VPN tunnel")
        if !p.hasWiFi && !p.cellularActive && !p.hasVPN { return "No Wi‑Fi, cellular or VPN connection." }
        return parts.joined(separator: " · ")
    }

    static func verdict(phone: PhoneInterfaces, lan: PathReport?, overlay: PathReport?, legacy: PathReport?, paired: Bool) -> Verdict {
        let viaLAN = lan?.reachable == true
        let viaOverlay = overlay?.reachable == true || legacy?.reachable == true
        let overlayUsed = overlay?.reachable == true ? overlay : legacy
        let net = (viaLAN ? lan : overlayUsed)?.probe?.network
        let securityTip: String? = {
            let used = viaLAN ? lan : overlayUsed
            switch used?.protection {
            case .none?: return "Traffic on site Wi‑Fi isn't encrypted yet. Pair this phone with your gateway in Settings › Security."
            case .vpnOnly?:
                return paired
                    ? "HTTPS didn't answer on the overlay, so the app is using legacy HTTP inside the VPN (still encrypted by the VPN)."
                    : "Pair this phone with your gateway in Settings › Security so site Wi‑Fi traffic is encrypted too."
            default: return nil
            }
        }()

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
            if phone.hasVPN { tips.append("Your VPN is on as well; the app uses whichever path answers, preferring site Wi‑Fi.") }
            if let securityTip { tips.insert(securityTip, at: 0) }
            let encrypted = lan?.protection == .tls
            return Verdict(
                tone: encrypted ? .good : .caution, icon: encrypted ? "wifi" : "lock.open.fill",
                title: encrypted ? "You're on site Wi‑Fi" : "On site Wi‑Fi, unencrypted",
                message: encrypted
                    ? "Your phone reaches the site gateway directly on the local network over HTTPS, checked against your site's pinned certificate. Nothing goes over the internet."
                    : "Your phone reaches the site gateway directly on the local network using legacy HTTP. Nothing goes over the internet, but anyone on this Wi‑Fi could read the traffic.",
                tips: tips
            )
        }
        if viaOverlay {
            var tips: [String] = []
            if let securityTip { tips.append(securityTip) }
            if phone.hasWiFi && phone.hasVPN && lan != nil {
                tips.append("You're on Wi‑Fi too, but with the VPN on iOS sends site addresses through the tunnel, so the direct Wi‑Fi path can't be used. Everything still works through the overlay.")
            }
            return Verdict(
                tone: .good, icon: "lock.shield.fill",
                title: "Connected through your private overlay",
                message: "Your LOJO VPN profile is carrying traffic over the encrypted private overlay. Your devices stay off the public internet.",
                tips: tips
            )
        }

        let reports = [lan, overlay, legacy].compactMap { $0 }
        if let blocked = reports.first(where: { report in
            if case .transport(let f)? = report.probe?.error { return f.isATSBlock }
            return false
        }) {
            return Verdict(
                tone: .bad, icon: "lock.trianglebadge.exclamationmark",
                title: "iOS blocked the connection",
                message: "iOS App Transport Security refused plain HTTP to \(blocked.address). This is an app configuration problem, not your network\(blocked.tcpOK ? " — the gateway port itself answered" : "").",
                tips: ["Update LOJO Networks to the latest build.", "Share the diagnostics below with LOJO support."]
            )
        }

        if case .localNetworkDenied? = lan?.probe?.error, !viaOverlay {
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

        if let refused = reports.first(where: { $0.probe?.error?.tlsFailure != nil }),
           let tls = refused.probe?.error?.tlsFailure {
            var tips: [String]
            switch tls.kind {
            case .notPaired:
                tips = ["Scan the gateway's pairing QR code with the iPhone Camera app, or paste the code in Settings › Security."]
            case .pinMismatch, .pairingMismatch:
                tips = ["If your installer rotated the site certificate authority, scan the new pairing code.",
                        "Otherwise, don't pair again — check what's answering at \(refused.address)."]
            case .hostnameMismatch:
                tips = ["On the gateway, add this address to SANS in site.env and run scripts/gateway-tls.sh rotate."]
            case .expired:
                tips = ["Check the date on this phone.", "On the gateway, run scripts/gateway-tls.sh rotate."]
            case .untrusted, .handshake:
                tips = ["Check the address uses the gateway's HTTPS port (8443).", "Share the diagnostics below with LOJO support."]
            }
            return Verdict(
                tone: .bad, icon: "lock.trianglebadge.exclamationmark",
                title: "Secure connection refused",
                message: "\(refused.path.title) (\(refused.address)): \(tls.meaning) [\(tls.technical)]",
                tips: tips
            )
        }

        if let open = reports.first(where: { $0.tcpOK && !$0.reachable }) {
            return Verdict(
                tone: .bad, icon: "exclamationmark.octagon.fill",
                title: "Gateway port open, but no valid reply",
                message: "Something at \(open.address) accepted the connection but didn't answer like a LOJO site gateway (\(open.probe?.error?.technical ?? "no reply")).",
                tips: ["Check that the gateway address in Settings is right.", "Restart the site gateway if it keeps happening."]
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
            message = "A VPN tunnel is active (\(phone.vpnSummary ?? "utun")), but the site gateway didn't respond through it."
            tips = [
                "Make sure the VPN profile you connected is your LOJO profile for this network.",
                "Check the overlay address in Settings matches your site gateway.",
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
    @EnvironmentObject private var router: Router
    @StateObject private var check = ConnectionCheck()
    @State private var showDiagnostics = true

    var body: some View {
        ScrollViewReader { proxy in
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
                    diagnostics
                        .id("diagnostics")
                    explainer
                }
                .padding(16)
            }
            .onChange(of: check.finishedAt) {
                guard store.launch.scroll == "diagnostics" else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation { proxy.scrollTo("diagnostics", anchor: .top) }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Connection")
        .toolbar {
            if store.isDemo {
                ToolbarItem(placement: .topBarLeading) { DemoBadge() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Gateway addresses")
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

    @ViewBuilder
    private var diagnostics: some View {
        if !check.reports.isEmpty || !check.phoneLines.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showDiagnostics.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Diagnostics")
                                .font(.headline)
                            Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = check.reportText(store: store)
                        Haptics.success()
                        store.show(Toast(style: .info, message: "Diagnostics copied. Paste them into a message to LOJO support."))
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(check.running)
                }
                if showDiagnostics {
                    DiagBlock(title: "This phone", systemImage: "iphone", ok: nil, lines: check.phoneLines)
                    ForEach(check.reports) { r in
                        DiagBlock(title: r.title, systemImage: r.path.systemImage, ok: r.reachable, lines: r.lines,
                                  footer: "\(r.totalMs) ms total")
                    }
                    Text("Addresses shown are private network addresses. Fingerprints identify public certificates; no passwords or keys are ever displayed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .card(padding: 14)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How your phone reaches your devices")
                .font(.subheadline.weight(.semibold))
            Text("At the site, the app talks to your site gateway directly over Wi‑Fi, using HTTPS once this phone is paired. Away from the site, your LOJO VPN profile joins this phone to your private overlay so the same gateway answers — encrypted by the VPN, and by HTTPS inside it. The app tries both automatically. Your cameras and controls are never published to the public internet.")
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

struct DiagBlock: View {
    let title: String
    let systemImage: String
    let ok: Bool?
    let lines: [DiagLine]
    var footer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(LojoTheme.accent)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let ok {
                    Text(ok ? "OK" : "FAILED")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(ok ? LojoTheme.online : LojoTheme.danger)
                }
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(line.status))
                        .font(.caption2)
                        .foregroundStyle(color(line.status))
                        .frame(width: 12)
                    Text(line.label)
                        .font(.caption.weight(.semibold))
                        .frame(width: 66, alignment: .leading)
                    Text(line.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.status == .fail ? LojoTheme.danger : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func icon(_ s: DiagLine.Status) -> String {
        switch s {
        case .ok: return "checkmark"
        case .fail: return "xmark"
        case .info: return "info"
        case .skip: return "minus"
        }
    }

    private func color(_ s: DiagLine.Status) -> Color {
        switch s {
        case .ok: return LojoTheme.online
        case .fail: return LojoTheme.danger
        case .info, .skip: return .secondary
        }
    }
}
