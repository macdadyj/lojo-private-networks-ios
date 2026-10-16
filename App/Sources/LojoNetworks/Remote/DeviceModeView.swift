import LojoRemote
import ReplayKit
import SwiftUI

struct DeviceModeView: View {
    @EnvironmentObject private var device: RemoteDeviceRuntime
    @EnvironmentObject private var router: Router
    @AppStorage(RemotePreferences.roleKey) private var role = "controller"
    @State private var shortcutName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This iPhone is the sound machine. Leave this screen open. Your other phone controls it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.relayStatus)
                            .font(.headline)
                            .accessibilityIdentifier("device.mode.status")
                        Text(device.batteryLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("device.mode.battery")
                        Text(playingLine)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("device.mode.playback")
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live screen")
                            .font(.headline)
                        Text("Start the broadcast here. The other phone can watch this screen. It cannot tap it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if device.broadcastReady {
                            BroadcastPicker()
                                .frame(height: 56)
                                .accessibilityIdentifier("device.broadcast")
                        } else {
                            Text("This install does not include the broadcast extension. The TestFlight build of LOJO Networks does. Sound, volume, sleep, and schedules still work.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("device.broadcast.missing")
                        }
                    }
                    .card()

                    shortcutNames
                    if !device.schedules.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Schedules on this iPhone")
                                .font(.headline)
                            ForEach(device.schedules) { schedule in
                                Text("\(schedule.soundTitle) · \(schedule.windowLabel)\(schedule.enabled ? "" : " · off")")
                                    .font(.subheadline)
                            }
                        }
                        .card()
                    }

                    NavigationLink {
                        RemoteHelpView()
                    } label: {
                        Label("What this can and cannot do", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("device.help")

                    Button("Use this iPhone as the controller") {
                        role = "controller"
                    }
                    .accessibilityIdentifier("device.mode.exit")
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(RemoteHelpCopy.productName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("device.settings")
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var shortcutNames: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts on this iPhone")
                .font(.headline)
            ForEach(device.shortcuts) { shortcut in
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.builtin ? "\(shortcut.name) · sample" : shortcut.name)
                    Text(shortcut.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Shortcut name", text: $shortcutName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("device.shortcut.name")
                Button("Add") {
                    device.addShortcut(named: shortcutName)
                    shortcutName = ""
                }
                .accessibilityIdentifier("device.shortcut.add")
            }
            Text("Add the name of a Shortcut you already made. This phone cannot see inside it. Samples run here. Other names open the Shortcuts app only while this screen is open or a sound is playing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var playingLine: String {
        guard device.playback.playing else { return "Stopped" }
        return device.playback.title ?? "Playing"
    }
}

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = "com.lojo.PrivateNetworks.broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
