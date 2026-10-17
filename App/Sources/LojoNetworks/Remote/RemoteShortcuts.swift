import AppIntents
import Foundation
import LojoRemote

enum RemoteSoundChoice: String, AppEnum {
    case whiteNoise
    case pinkNoise
    case brownNoise
    case rain
    case fan

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Sound")
    }

    static var caseDisplayRepresentations: [RemoteSoundChoice: DisplayRepresentation] {
        [
            .whiteNoise: "White Noise",
            .pinkNoise: "Pink Noise",
            .brownNoise: "Brown Noise",
            .rain: "Rain",
            .fan: "Fan",
        ]
    }

    var soundID: String {
        switch self {
        case .whiteNoise: return BundledSound.whiteNoise.rawValue
        case .pinkNoise: return BundledSound.pinkNoise.rawValue
        case .brownNoise: return BundledSound.brownNoise.rawValue
        case .rain: return BundledSound.rain.rawValue
        case .fan: return BundledSound.fan.rawValue
        }
    }
}

struct PlaySoundIntent: AppIntent {
    static var title: LocalizedStringResource { "Play sound" }
    static var description: IntentDescription { IntentDescription("Plays a sound-machine sound.") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Sound", default: .whiteNoise)
    var sound: RemoteSoundChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = sound.soundID
        let spoken: String = await MainActor.run {
            RemoteIntentBridge.shared.play(soundID: title)
            return RemoteIntentBridge.shared.machine.snapshot(now: Date()).title ?? "the sound"
        }
        return .result(dialog: "Playing \(spoken)")
    }
}

struct StopSoundIntent: AppIntent {
    static var title: LocalizedStringResource { "Stop" }
    static var description: IntentDescription { IntentDescription("Stops the sound.") }
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { RemoteIntentBridge.shared.stop() }
        return .result(dialog: "Stopped")
    }
}

struct SetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource { "Set volume" }
    static var description: IntentDescription { IntentDescription("Sets the volume of the built-in sounds.") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Percent", default: 60)
    var percent: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clamped = min(100, max(0, percent))
        await MainActor.run { RemoteIntentBridge.shared.setVolume(percent: clamped) }
        return .result(dialog: "Volume \(clamped) percent")
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource { "Play Music playlist" }
    static var description: IntentDescription { IntentDescription("Plays a playlist from the Music library.") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Playlist")
    var playlist: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = playlist
        let spoken: String = await MainActor.run {
            RemoteIntentBridge.shared.playPlaylist(named: name)
            return RemoteIntentBridge.shared.machine.snapshot(now: Date()).message
                ?? "Playing \(name)"
        }
        return .result(dialog: "\(spoken)")
    }
}

struct SleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource { "Sleep timer" }
    static var description: IntentDescription { IntentDescription("Stops the sound after a number of minutes.") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Minutes", default: 30)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clamped = min(24 * 60, max(0, minutes))
        await MainActor.run { RemoteIntentBridge.shared.setSleep(minutes: clamped) }
        if clamped == 0 { return .result(dialog: "Sleep timer off") }
        return .result(dialog: "Sleep timer \(clamped) minutes")
    }
}

struct ReportStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "Report status" }
    static var description: IntentDescription { IntentDescription("Says what is currently playing.") }
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text: String = await MainActor.run { RemoteIntentBridge.shared.statusText() }
        return .result(value: text, dialog: "\(text)")
    }
}

struct LojoRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySoundIntent(),
            phrases: [
                "Play bedtime white noise with \(.applicationName)",
                "Play a sound with \(.applicationName)",
            ],
            shortTitle: "Bedtime white noise",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StopSoundIntent(),
            phrases: [
                "Turn the morning sound off with \(.applicationName)",
                "Stop sound with \(.applicationName)",
            ],
            shortTitle: "Morning off",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: SetVolumeIntent(),
            phrases: [
                "Set the volume with \(.applicationName)",
            ],
            shortTitle: "Set volume",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play a playlist with \(.applicationName)",
            ],
            shortTitle: "Play Music playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: SleepTimerIntent(),
            phrases: [
                "Set a sleep timer with \(.applicationName)",
            ],
            shortTitle: "Sleep timer",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: ReportStatusIntent(),
            phrases: [
                "Report status with \(.applicationName)",
            ],
            shortTitle: "Report status",
            systemImageName: "info.circle"
        )
    }
}
