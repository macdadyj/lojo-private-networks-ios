import LojoRemote
import SwiftUI

struct DeviceModeView: View {
    @EnvironmentObject private var device: RemoteDeviceRuntime
    @EnvironmentObject private var router: Router
    @AppStorage(RemotePreferences.roleKey) private var role = "controller"
    @AppStorage(RemotePreferences.controlModeKey) private var controlMode = true
    @State private var shortcutName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This phone is the sound machine. Your other phone controls it while Control mode is on.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Control mode", isOn: $controlMode)
                            .font(.headline)
                            .accessibilityIdentifier("device.control-mode")
                        Text(controlMode
                             ? "On. A sound that is playing keeps going with the screen locked, and play, stop, and schedules still arrive. Closing the app from the app switcher stops control until you open it again. With nothing playing, iOS may suspend this app soon after the screen locks, and the other phone will show Not reachable."
                             : "Off. This phone is not listening. The other phone will show Not reachable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .card()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.relayStatus)
                            .font(.headline)
                            .accessibilityIdentifier("device.mode.status")
                        if !device.relayDetail.isEmpty {
                            Text(device.relayDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("device.mode.detail")
                        }
                        Text(device.batteryLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("device.mode.battery")
                        Text(playingLine)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("device.mode.playback")
                    }
                    .card()

                    shortcutNames
                    if !device.schedules.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Schedules on this phone")
                                .font(.headline)
                            ForEach(device.schedules) { schedule in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(schedule.soundTitle)
                                        .font(.subheadline.weight(.semibold))
                                    Text(schedule.enabled ? schedule.windowLabel : "\(schedule.windowLabel) · off")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
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

