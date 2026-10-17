import LojoRemote
import SwiftUI

enum RemoteRoute: Hashable {
    case panel(String)
    case schedule(String)
    case help
}

struct RemoteRootView: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var remote: RemoteControllerStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [RemoteRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.isDemo || remote.demo {
                        DemoBadge()
                    }
                    if let message = remote.message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if remote.phones.isEmpty {
                        EmptyStateCard(
                            systemImage: "iphone.gen3",
                            title: "No spare iPhones yet",
                            message: "On the spare iPhone, open LOJO Networks and turn on iPhone Remote Controller. Leave that screen open. It shows up here with its battery once the relay can see it.",
                            primary: nil,
                            secondary: nil
                        )
                    } else {
                        SectionTitle(text: "Devices", trailing: "\(remote.phones.count)")
                        VStack(spacing: 0) {
                            ForEach(Array(remote.phones.enumerated()), id: \.element.id) { index, phone in
                                Button {
                                    path.append(.panel(phone.id))
                                } label: {
                                    RemoteDeviceRow(phone: phone)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("remote.device.row")
                                if index < remote.phones.count - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .card(padding: 0)
                    }
                    Text(RemoteHelpCopy.limitsShort)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        path.append(.help)
                    } label: {
                        Label("What this can and cannot do", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("remote.help")
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(RemoteHelpCopy.productName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RemoteRoute.self) { route in
                switch route {
                case .panel(let id):
                    RemotePanelView(phoneID: id)
                case .schedule(let id):
                    ScheduleEditorView(phoneID: id)
                case .help:
                    RemoteHelpView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("remote.done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await remote.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh devices")
                    .accessibilityIdentifier("remote.refresh")
                }
            }
        }
        .task {
            await openLaunchScreen()
            while !Task.isCancelled {
                await remote.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func openLaunchScreen() async {
        guard path.isEmpty, let screen = store.launch.remoteScreen else { return }
        if remote.phones.isEmpty { await remote.refresh() }
        let id = remote.phones.first?.id ?? RemotePhone.demoSpare.id
        switch screen {
        case "panel": path = [.panel(id)]
        case "schedule": path = [.schedule(id)]
        case "help": path = [.help]
        default: break
        }
    }
}

struct RemoteDeviceRow: View {
    let phone: RemotePhone

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.title2)
                .foregroundStyle(phone.online ? LojoTheme.accent : .secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text(phone.statusLabel)
                        .foregroundStyle(phone.online ? LojoTheme.online : .secondary)
                    Text(phone.batteryLabel)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phone.name), \(phone.statusLabel), \(phone.batteryLabel)")
    }
}
