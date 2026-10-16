import Foundation
import LojoRemote
import UIKit

/// Shared by the relay loop and the Shortcuts / Siri intents so both drive one player.
@MainActor
final class RemoteIntentBridge {
    static let shared = RemoteIntentBridge()

    let machine = SoundMachine()
    var sceneIsActive = true
    private var customNames: [String]

    private init() {
        customNames = Self.loadNames()
    }

    func shortcuts() -> [NamedShortcut] {
        let samples = SampleAutomations.shortcuts
        let extras = customNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                !name.isEmpty && samples.allSatisfy { $0.name.caseInsensitiveCompare(name) != .orderedSame }
            }
            .map { NamedShortcut(name: $0, builtin: false, summary: "Shortcut on this iPhone") }
        return samples + extras
    }

    func addName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return }
        guard shortcuts().allSatisfy({ $0.name.caseInsensitiveCompare(name) != .orderedSame }) else { return }
        customNames.append(name)
        Self.store(customNames)
    }

    func play(soundID: String) {
        machine.play(soundID: soundID)
    }

    func stop() {
        machine.stop()
    }

    func setVolume(percent: Int) {
        machine.setVolume(Double(percent) / 100)
    }

    func playPlaylist(named name: String) {
        machine.playPlaylist(named: name)
    }

    func setSleep(minutes: Int) {
        machine.setSleep(minutes: minutes, now: Date())
    }

    func statusText() -> String {
        let snap = machine.snapshot(now: Date())
        let playing = snap.playing ? (snap.title ?? "Playing") : "Stopped"
        let volume = Int((snap.volume * 100).rounded())
        let sleep: String
        if let seconds = snap.sleepRemainingSec, seconds > 0 {
            sleep = ", sleep \(max(1, seconds / 60)) min"
        } else {
            sleep = ""
        }
        return "\(playing), volume \(volume)%\(sleep)"
    }

    /// Samples run in this process. Other names open the Shortcuts app when iOS allows it.
    @discardableResult
    func run(name: String, now: Date) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playing = machine.snapshot(now: now).playing
        switch ShortcutLink.availability(name: trimmed, foreground: sceneIsActive, audioPlaying: playing) {
        case .inApp:
            guard let sample = SampleAutomations.match(name: trimmed) else {
                return "That sample is not on this iPhone."
            }
            switch sample.action {
            case .play(let soundID):
                machine.play(soundID: soundID)
            case .stop:
                machine.stop()
            }
            return sample.summary
        case .shortcutsURL:
            guard let url = ShortcutLink.runURL(name: trimmed) else {
                machine.note("That Shortcut name cannot be opened.")
                return "That Shortcut name cannot be opened."
            }
            UIApplication.shared.open(url)
            machine.note("Asked Shortcuts to run \(trimmed).")
            return "Asked Shortcuts to run \(trimmed)."
        case .unavailable:
            let text = "Leave iPhone Remote Controller open, or keep a sound playing, before running \(trimmed). iOS will not open Shortcuts from a suspended app."
            machine.note(text)
            return text
        }
    }

    private static let namesKey = "lojo.remote.shortcutNames"

    private static func loadNames() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: namesKey),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    private static func store(_ names: [String]) {
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: namesKey)
        }
    }
}
