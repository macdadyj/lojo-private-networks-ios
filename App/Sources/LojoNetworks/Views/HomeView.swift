import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var router: Router

    private var online: [Device] { store.devices.filter(\.online) }
    private var offline: [Device] { store.devices.filter { !$0.online } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConnectionHealthCard()
                if store.isStale {
                    StaleBanner()
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(store.displayNetworkName)
        .toolbar {
            if store.isDemo {
                ToolbarItem(placement: .topBarLeading) { DemoBadge() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .refreshable { await store.refresh(.user) }
    }

    @ViewBuilder
    private var content: some View {
        if store.devices.isEmpty {
            switch store.link {
            case .connecting:
                LoadingCard(text: "Looking for your network…")
            case .unreachable:
                EmptyStateCard(
                    systemImage: "wifi.exclamationmark",
                    title: "Can't reach your network",
                    message: store.localNetworkBlocked
                        ? "iOS is blocking Local Network access for this app. Turn it on in Settings › Privacy & Security › Local Network, or connect your LOJO VPN profile."
                        : "\(store.unreachableReason()) The connection check shows exactly which step failed.",
                    primary: ("Run connection check", { router.tab = .check }),
                    secondary: ("Explore the demo", { store.isDemo = true })
                )
            case .connected, .demo:
                EmptyStateCard(
                    systemImage: "shippingbox",
                    title: "No devices yet",
                    message: "Devices appear here as soon as they join your private network. Install the LOJO device agent on a Raspberry Pi, camera box or computer at your site.",
                    primary: nil,
                    secondary: ("Explore the demo", { store.isDemo = true })
                )
            }
        } else {
            SummaryTiles()
            if !online.isEmpty {
                SectionTitle(text: "Online", trailing: "\(online.count)")
                roster(online)
            }
            if !offline.isEmpty {
                SectionTitle(text: "Offline", trailing: "\(offline.count)")
                roster(offline)
            }
            Text(footerText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    private var footerText: String {
        if store.isDemo { return "Sample network. Nothing here controls real hardware." }
        return "Your devices are reachable only through your private network — none are exposed to the public internet."
    }

    private func roster(_ list: [Device]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, device in
                NavigationLink(value: device.key) {
                    DeviceRow(device: device)
                }
                .buttonStyle(.plain)
                if index < list.count - 1 {
                    Divider().padding(.leading, 72)
                }
            }
        }
        .card(padding: 0)
    }
}

struct ConnectionHealthCard: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var router: Router

    var body: some View {
        Button {
            router.tab = .check
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Image(systemName: icon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, isActive: store.link == .connecting)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let codes = store.failureSummary, !codes.isEmpty {
                        Text(codes)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityHint("Opens the connection check")
        .padding(.top, 4)
    }

    private var icon: String {
        switch store.link {
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .connected(let ep): return store.hubConnected ? ep.path.systemImage : "exclamationmark.triangle.fill"
        case .unreachable: return "wifi.slash"
        case .demo: return "lock.shield.fill"
        }
    }

    private var tint: Color {
        switch store.link {
        case .connecting: return LojoTheme.accent
        case .connected: return store.hubConnected ? LojoTheme.online : LojoTheme.warning
        case .unreachable: return LojoTheme.danger
        case .demo: return LojoTheme.online
        }
    }

    private var title: String {
        switch store.link {
        case .connecting: return "Connecting…"
        case .connected(let ep):
            return store.hubConnected ? "Connected · \(ep.path.title)" : "Gateway up · cloud hub offline"
        case .unreachable: return "Not connected"
        case .demo: return "Connected · Private overlay"
        }
    }

    private var subtitle: String {
        let latency = store.latencyMs.map { " · \($0) ms" } ?? ""
        switch store.link {
        case .connecting:
            return "Trying site Wi‑Fi, then the private overlay."
        case .connected(let ep):
            if !store.hubConnected { return "Cameras and controls pause until the gateway reconnects." }
            switch ep.path {
            case .lan: return "Direct on the local network\(latency)"
            case .overlay: return "Through your LOJO VPN, nothing public\(latency)"
            }
        case .unreachable:
            return "\(store.unreachableReason()) Tap for details."
        case .demo:
            return "Sample network\(latency)"
        }
    }
}

struct StaleBanner: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var router: Router

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(LojoTheme.warning)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Showing the last known state")
                    .font(.subheadline.weight(.semibold))
                Text("Updated \(RelativeTime.text(store.lastSuccess)). Device status and controls may be out of date until your network is reachable again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Check connection") { router.tab = .check }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 2)
            }
        }
        .card(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: LojoTheme.cornerRadius, style: .continuous)
                .strokeBorder(LojoTheme.warning.opacity(0.5))
        )
        .accessibilityElement(children: .combine)
    }
}

struct SummaryTiles: View {
    @EnvironmentObject private var store: NetworkStore

    var body: some View {
        HStack(spacing: 10) {
            tile(value: store.onlineCount, label: "Online", icon: "circle.fill", tint: LojoTheme.online)
            tile(value: store.offlineCount, label: "Offline", icon: "circle", tint: .secondary)
            tile(value: store.cameraCount, label: "Cameras", icon: "video.fill", tint: LojoTheme.accent)
            tile(value: store.outputCount, label: "Controls", icon: "switch.2", tint: LojoTheme.control)
        }
    }

    private func tile(value: Int, label: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.title2.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .card(padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 14) {
            DeviceIcon(kind: device.kind, online: device.online)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if device.camera.enabled { Chip(text: "Camera", systemImage: "camera.fill") }
                    if !device.gpio.isEmpty {
                        Chip(text: device.gpio.count == 1 ? "1 control" : "\(device.gpio.count) controls", systemImage: "switch.2")
                    }
                    if device.location != nil { Chip(text: "Map", systemImage: "mappin") }
                }
            }
            Spacer(minLength: 4)
            StatusDot(style: device.online ? .online : .offline)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Opens device details")
        .accessibilityAddTraits(.isButton)
    }

    private var statusLine: String {
        if device.online {
            return "\(device.siteName) · updated \(RelativeTime.text(device.lastUpdate))"
        }
        return "\(device.siteName) · offline \(RelativeTime.text(device.statusSince))"
    }

    private var accessibilitySummary: String {
        var parts = [device.displayName, device.online ? "online" : "offline", device.siteName]
        if device.camera.enabled { parts.append("has camera") }
        if !device.gpio.isEmpty { parts.append("\(device.gpio.count) controls") }
        return parts.joined(separator: ", ")
    }
}

struct LoadingCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .card()
    }
}

struct EmptyStateCard: View {
    let systemImage: String
    let title: String
    let message: String
    var primary: (String, () -> Void)?
    var secondary: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(LojoTheme.brandGradient)
                .padding(.top, 8)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let primary {
                Button(primary.0, action: primary.1)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
            if let secondary {
                Button(secondary.0, action: secondary.1)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(8)
        .card(padding: 20)
    }
}
