import LojoRemote
import SwiftUI

private enum PanelPage: Hashable, Identifiable {
    case schedule
    case help

    var id: Self { self }
}

struct RemotePanelView: View {
    let phoneID: String
    @EnvironmentObject private var remote: RemoteControllerStore
    @State private var panelPage: PanelPage?
    @State private var showLibrary = false

    private var phone: RemotePhone? { remote.phones.first { $0.id == phoneID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let phone {
                    status(phone)
                    playback(phone)
                    controls
                    sounds(phone)
                    volume(phone)
                    if !phone.shortcuts.isEmpty {
                        shortcuts(phone)
                    }
                    sleep
                    links
                } else {
                    EmptyStateCard(
                        systemImage: "iphone.slash",
                        title: "This phone left the site",
                        message: "It stopped checking in. On that phone, open Remote Controller and leave the screen up. This phone shows the gateway address and the error when the list cannot be loaded.",
                        primary: nil,
                        secondary: nil
                    )
                }
                if let message = remote.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(phone?.name ?? RemoteHelpCopy.productName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $panelPage) { page in
            panelDestination(page)
        }
        .navigationDestination(isPresented: $showLibrary) {
            MusicLibraryView(phoneID: phoneID)
        }
        .safeAreaInset(edge: .bottom) {
            if let phone, phone.playback?.playing == true || phone.playback?.title != nil {
                nowPlayingBar(phone)
            }
        }
    }

    @ViewBuilder
    private func panelDestination(_ page: PanelPage) -> some View {
        switch page {
        case .schedule:
            ScheduleEditorView(phoneID: phoneID)
        case .help:
            RemoteHelpView()
        }
    }

    private func nowPlayingBar(_ phone: RemotePhone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playbackLine(phone))
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 16) {
                Button {
                    Task { await remote.skip(phoneID: phoneID, next: false) }
                } label: {
                    Image(systemName: "backward.fill")
                }
                .accessibilityIdentifier("remote.transport.previous")
                Button {
                    Task {
                        if phone.playback?.playing == true {
                            await remote.stop(phoneID: phoneID)
                        } else {
                            await remote.play(phoneID: phoneID)
                        }
                    }
                } label: {
                    Image(systemName: phone.playback?.playing == true ? "pause.fill" : "play.fill")
                }
                .accessibilityIdentifier("remote.transport.play")
                Button {
                    Task { await remote.skip(phoneID: phoneID, next: true) }
                } label: {
                    Image(systemName: "forward.fill")
                }
                .accessibilityIdentifier("remote.transport.next")
                Button {
                    showLibrary = true
                    Task { await remote.browse(phoneID: phoneID, scope: "queue") }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Queue")
                .accessibilityIdentifier("remote.transport.queue")
            }
            .font(.title3)
            Text("Built-in sounds use the volume slider. Music follows the spare phone's volume buttons.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func status(_ phone: RemotePhone) -> some View {
        HStack(spacing: 12) {
            StatusDot(style: phone.online ? .online : .offline, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.statusLabel)
                    .font(.headline)
                    .foregroundStyle(phone.online ? LojoTheme.online : .secondary)
                Text(phone.batteryLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(phone.online ? "Reachable" : "Not reachable")
                    .font(.subheadline.weight(.semibold))
                Text(phone.online
                     ? "Control mode is answering."
                     : "It answers while Control mode is on and iOS is letting the app run. A playing sound keeps it awake with the screen locked. Closing the app from the app switcher stops control until it is opened again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityIdentifier("remote.status")
    }

    private func playback(_ phone: RemotePhone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(playbackLine(phone))
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("remote.playback")
            if let message = phone.playback?.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let remaining = phone.playback?.sleepRemainingSec, remaining > 0 {
                Text("Sleep timer · \(remaining / 60) min \(remaining % 60) s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("remote.sleep.remaining")
            }
        }
        .card()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.light()
                Task { await remote.play(phoneID: phoneID) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("remote.play")

            Button {
                Haptics.light()
                Task { await remote.stop(phoneID: phoneID) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("remote.stop")
        }
    }

    private func sounds(_ phone: RemotePhone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sound")
                .font(.headline)
            ForEach(BundledSound.allCases) { sound in
                soundButton(id: sound.rawValue, title: sound.title, systemImage: sound.systemImage)
            }
            Button {
                showLibrary = true
            } label: {
                HStack {
                    Label("Music library", systemImage: "music.note.list")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("remote.library.open")
            Text("Search, recent songs, playlists, artists, albums, and songs come from the spare phone. Large libraries arrive one page at a time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func soundButton(id: String, title: String, systemImage: String) -> some View {
        Button {
            remote.selectedSoundID = id
            Haptics.selection()
        } label: {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
                if remote.selectedSoundID == id {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remote.sound.\(id)")
        .accessibilityAddTraits(remote.selectedSoundID == id ? .isSelected : [])
    }

    private func volume(_ phone: RemotePhone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volume")
                .font(.headline)
            HStack {
                Button {
                    Task { await remote.setVolume(phoneID: phoneID, volume: (phone.playback?.volume ?? 0.6) - 0.1) }
                } label: {
                    Image(systemName: "speaker.fill")
                }
                .accessibilityIdentifier("remote.volume.down")
                Slider(value: Binding(
                    get: { phone.playback?.volume ?? 0.6 },
                    set: { value in Task { await remote.setVolume(phoneID: phoneID, volume: value) } }
                ), in: 0...1)
                .accessibilityIdentifier("remote.volume")
                Button {
                    Task { await remote.setVolume(phoneID: phoneID, volume: (phone.playback?.volume ?? 0.6) + 0.1) }
                } label: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .accessibilityIdentifier("remote.volume.up")
            }
            Text("Built-in sounds use this slider. Apple Music follows the spare iPhone's volume buttons.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func shortcuts(_ phone: RemotePhone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts")
                .font(.headline)
            ForEach(phone.shortcuts) { shortcut in
                Button {
                    Haptics.light()
                    Task { await remote.runShortcut(phoneID: phoneID, name: shortcut.name) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortcut.name)
                        Text(shortcut.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(shortcut.accessibilityID)
            }
            Text("Bedtime white noise and Morning off run on the spare iPhone. Any other name opens the Shortcuts app there, and only while that screen is open or a sound is already playing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var sleep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sleep timer")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sleepButton("15 min", minutes: 15)
                    sleepButton("30 min", minutes: 30)
                }
                HStack {
                    sleepButton("60 min", minutes: 60)
                    sleepButton("Off", minutes: 0)
                }
            }
        }
        .card()
    }

    private func sleepButton(_ title: String, minutes: Int) -> some View {
        Button(title) {
            Task { await remote.setSleep(phoneID: phoneID, minutes: minutes) }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(minutes == 0 ? "remote.sleep.off" : "remote.sleep.\(minutes)")
    }

    private var links: some View {
        VStack(spacing: 0) {
            Button {
                panelPage = .schedule
            } label: {
                linkRow("Schedules", systemImage: "clock")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("remote.schedule")
            Divider()
            Button {
                panelPage = .help
            } label: {
                linkRow("Help", systemImage: "questionmark.circle")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("remote.help.panel")
        }
        .card(padding: 0)
    }

    private func linkRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func playbackLine(_ phone: RemotePhone) -> String {
        guard let playback = phone.playback, playback.playing else { return "Stopped" }
        return playback.title ?? "Playing"
    }
}

struct ScheduleEditorView: View {
    let phoneID: String
    @EnvironmentObject private var remote: RemoteControllerStore
    @Environment(\.dismiss) private var dismiss
    @State private var schedules: [SoundSchedule] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bedtime and morning")
                        .font(.title3.weight(.semibold))
                    Text("White noise starts at 8:00 PM and stops at 6:00 AM. The spare phone runs that window while Remote Controller stays open there. Bedtime white noise and Morning off are also Shortcuts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        addBedtime()
                    } label: {
                        Label("Add bedtime white noise", systemImage: "moon.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("remote.schedule.add-overnight")
                }
                .card()

                if schedules.isEmpty {
                    EmptyStateCard(
                        systemImage: "clock",
                        title: "No schedule yet",
                        message: "Add bedtime white noise. You can change the sound and the start and stop times before you save.",
                        primary: nil,
                        secondary: nil
                    )
                }

                ForEach($schedules) { $schedule in
                    scheduleCard($schedule)
                }

                Button {
                    Task {
                        await remote.save(schedules: schedules, phoneID: phoneID)
                        dismiss()
                    }
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("remote.schedule.save")
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            schedules = remote.phones.first { $0.id == phoneID }?.schedules ?? []
        }
    }

    private func addBedtime() {
        let sample = SampleAutomations.bedtimeSchedule
        guard !schedules.contains(where: { $0.id == sample.id }) else { return }
        schedules.append(sample)
    }

    private func scheduleCard(_ schedule: Binding<SoundSchedule>) -> some View {
        let value = schedule.wrappedValue
        return VStack(alignment: .leading, spacing: 12) {
            Text(value.soundTitle)
                .font(.headline)
            Text(value.windowLabel)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Plays \(value.windowLabel)")
            Toggle("Enabled", isOn: schedule.enabled)
            Picker("Sound", selection: schedule.soundID) {
                ForEach(BundledSound.allCases) { sound in
                    Text(sound.title).tag(sound.rawValue)
                }
            }
            DatePicker("Starts", selection: binding(minutes: schedule.startMinutes), displayedComponents: .hourAndMinute)
            DatePicker("Stops", selection: binding(minutes: schedule.stopMinutes), displayedComponents: .hourAndMinute)
            Button("Remove", role: .destructive) {
                schedules.removeAll { $0.id == value.id }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    private func binding(minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Self.date(minutes: minutes.wrappedValue) },
            set: { minutes.wrappedValue = Self.minutes(from: $0) }
        )
    }

    private static func date(minutes: Int) -> Date {
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        parts.hour = ScheduleClock.normalize(minutes) / 60
        parts.minute = ScheduleClock.normalize(minutes) % 60
        return Calendar.current.date(from: parts) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        ScheduleClock.minutes(from: date)
    }
}

struct RemoteHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Text(RemoteHelpCopy.limits)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .accessibilityIdentifier("remote.help.limits")
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(RemoteHelpCopy.productName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("remote.help.done")
            }
        }
    }
}
