import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var store: NetworkStore
    @State private var filter: EventKind.Category = .all

    private var filtered: [NetworkEvent] {
        store.events.filter { filter == .all || $0.kind.category == filter }
    }

    private var grouped: [(day: Date, events: [NetworkEvent])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { ($0, dict[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(EventKind.Category.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .onChange(of: filter) { Haptics.selection() }
            }

            if store.isStale {
                Section {
                    Label("Showing activity from \(RelativeTime.text(store.lastSuccess)). New events will appear when your network is reachable.", systemImage: "clock.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.warning)
                }
            }

            if grouped.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(grouped, id: \.day) { group in
                    Section(dayTitle(group.day)) {
                        ForEach(group.events) { ev in
                            EventRow(event: ev)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .toolbar {
            if store.isDemo {
                ToolbarItem(placement: .topBarLeading) { DemoBadge() }
            }
        }
        .refreshable { await store.refresh(.user) }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch store.link {
        case .connecting:
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        case .unreachable where store.lastSuccess == nil:
            ContentUnavailableView(
                "No activity to show",
                systemImage: "wifi.slash",
                description: Text("Your network isn't reachable from this phone. Activity loads once you're on site Wi‑Fi or the private overlay.")
            )
        default:
            ContentUnavailableView(
                filter == .all ? "Nothing yet" : "No \(filter.rawValue.lowercased()) activity",
                systemImage: "clock",
                description: Text("Devices joining or leaving, camera captures and control changes show up here.")
            )
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

struct EventRow: View {
    let event: NetworkEvent
    var compact = false
    @EnvironmentObject private var store: NetworkStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(style.tint.opacity(0.16))
                Image(systemName: style.icon)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(style.tint)
            }
            .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(compact ? .subheadline : .body)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(compact ? RelativeTime.text(event.date) : RelativeTime.clock(event.date))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, compact ? 2 : 4)
        .accessibilityElement(children: .combine)
    }

    private var deviceName: String {
        guard let key = event.device else { return "A device" }
        return store.device(key: key)?.displayName ?? DeviceNaming.displayName(key)
    }

    private var pinTitle: String {
        guard let key = event.device, let pin = event.pin else { return "An output" }
        return store.device(key: key)?.gpio.first { $0.pin == pin }?.title ?? "Output \(pin)"
    }

    private var title: String {
        switch event.kind {
        case .deviceOnline: return "\(deviceName) came online"
        case .deviceOffline: return "\(deviceName) went offline"
        case .captureRequested: return "Still requested from \(deviceName)"
        case .captureCompleted: return "New still from \(deviceName)"
        case .captureFailed: return "Capture failed on \(deviceName)"
        case .gpioSet: return "\(pinTitle) turned \(event.value == 1 ? "ON" : "OFF") on \(deviceName)"
        case .hubConnected: return "Site gateway connected to the cloud hub"
        case .hubDisconnected: return "Site gateway lost the cloud hub"
        case .other: return event.type
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let detail = event.detail, !detail.isEmpty {
            parts.append(detail.prefix(1).uppercased() + detail.dropFirst())
        }
        switch event.via {
        case "lan": parts.append("From a phone on site Wi‑Fi")
        case "overlay": parts.append("From a phone on the private overlay")
        case "local": parts.append("From the site gateway")
        default: break
        }
        if event.kind == .gpioSet, let pin = event.pin { parts.append("header pin \(pin)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var style: (icon: String, tint: Color) {
        switch event.kind {
        case .deviceOnline: return ("arrow.up.circle.fill", LojoTheme.online)
        case .deviceOffline: return ("arrow.down.circle", .secondary)
        case .captureRequested: return ("camera", LojoTheme.accent)
        case .captureCompleted: return ("photo.fill", LojoTheme.accent)
        case .captureFailed: return ("exclamationmark.triangle.fill", LojoTheme.warning)
        case .gpioSet: return ("power", event.value == 1 ? LojoTheme.online : LojoTheme.accentDeep)
        case .hubConnected: return ("cloud.fill", LojoTheme.online)
        case .hubDisconnected: return ("icloud.slash", LojoTheme.danger)
        case .other: return ("circle", .secondary)
        }
    }
}
