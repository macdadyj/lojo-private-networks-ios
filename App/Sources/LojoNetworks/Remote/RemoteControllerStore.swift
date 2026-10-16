import Foundation
import LojoRemote
import UIKit

struct AdaptiveRelayTransport: RelayTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let url = request.url, url.scheme == "http", let host = url.host, !RelayEndpoint.isLoopback(host) {
            return try await PlainHTTP.send(request, timeout: 8)
        }
        return try await URLSessionRelayTransport().send(request)
    }
}

enum RemotePreferences {
    static let urlKey = "lojo.remote.relayURL"
    static let codeKey = "lojo.remote.networkCode"
    static let roleKey = "lojo.remote.role"
    static let nameKey = "lojo.remote.name"
    static let phoneIDKey = "lojo.remote.phoneID"

    static func relayURL(launch: LaunchOptions) -> URL? {
        if let text = launch.relayURLText { return RelayEndpoint.url(from: text) }
        return RelayEndpoint.url(from: UserDefaults.standard.string(forKey: urlKey) ?? "")
    }

    static func networkCode(launch: LaunchOptions) -> String {
        if let code = launch.networkCode, !code.isEmpty { return code }
        return UserDefaults.standard.string(forKey: codeKey) ?? ""
    }

    static func phoneID(launch: LaunchOptions) -> String {
        if let id = launch.remotePhoneID, !id.isEmpty { return id }
        if let saved = UserDefaults.standard.string(forKey: phoneIDKey), !saved.isEmpty { return saved }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: phoneIDKey)
        return created
    }

    static func phoneName(launch: LaunchOptions) -> String {
        if let name = launch.remoteName, !name.isEmpty { return name }
        if let saved = UserDefaults.standard.string(forKey: nameKey), !saved.isEmpty { return saved }
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceName.isEmpty ? "Spare iPhone" : deviceName
    }
}

@MainActor
final class RemoteControllerStore: ObservableObject {
    @Published private(set) var phones: [RemotePhone] = []
    @Published var message: String?
    @Published var frame: Data?
    @Published var selectedSoundID = BundledSound.whiteNoise.rawValue
    let demo: Bool
    private let launch: LaunchOptions

    init(launch: LaunchOptions) {
        self.launch = launch
        demo = launch.remoteDemo
        if demo {
            phones = [RemotePhone.demoSpare]
        }
    }

    func refresh() async {
        if demo { return }
        guard let client = client() else {
            message = "Add the relay address and network code in Settings. The relay runs on your site gateway."
            return
        }
        do {
            phones = try await client.list()
            message = nil
        } catch {
            message = "Can't reach the relay."
        }
    }

    func play(phoneID: String) async {
        await send(CommandBody(kind: .play, soundID: selectedSoundID), phoneID: phoneID) {
            $0.playback = PlaybackSnapshot(
                playing: true,
                soundID: selectedSoundID,
                title: soundTitle(selectedSoundID),
                volume: $0.playback?.volume ?? 0.6,
                source: selectedSoundID.hasPrefix("music:") ? .appleMusic : .bundled
            )
        }
    }

    func stop(phoneID: String) async {
        await send(CommandBody(kind: .stop), phoneID: phoneID) {
            let volume = $0.playback?.volume ?? 0.6
            $0.playback = PlaybackSnapshot(playing: false, volume: volume, source: .none)
        }
    }

    func setVolume(phoneID: String, volume: Double) async {
        let clamped = min(1, max(0, volume))
        await send(CommandBody(kind: .setVolume, volume: clamped), phoneID: phoneID) {
            var playback = $0.playback ?? .idle
            playback.volume = clamped
            $0.playback = playback
        }
    }

    func runShortcut(phoneID: String, name: String) async {
        await send(CommandBody(kind: .runShortcut, shortcutName: name), phoneID: phoneID) { phone in
            guard let sample = SampleAutomations.match(name: name) else { return }
            switch sample.action {
            case .play(let soundID):
                phone.playback = PlaybackSnapshot(
                    playing: true,
                    soundID: soundID,
                    title: BundledSound(rawValue: soundID)?.title ?? "Playing",
                    volume: phone.playback?.volume ?? 0.6,
                    source: .bundled
                )
            case .stop:
                phone.playback = PlaybackSnapshot(playing: false, volume: phone.playback?.volume ?? 0.6, source: .none)
            }
        }
    }

    func setSleep(phoneID: String, minutes: Int) async {
        await send(CommandBody(kind: .setSleep, sleepMinutes: minutes), phoneID: phoneID) {
            var playback = $0.playback ?? .idle
            playback.sleepRemainingSec = minutes > 0 ? minutes * 60 : nil
            $0.playback = playback
        }
    }

    func save(schedules: [SoundSchedule], phoneID: String) async {
        if demo {
            update(phoneID) { $0.schedules = schedules }
            return
        }
        guard let client = client() else { return }
        do {
            let saved = try await client.saveSchedules(schedules, phoneID: phoneID)
            update(phoneID) {
                $0.schedules = saved.schedules
                $0.scheduleRevision = saved.scheduleRevision
            }
            message = nil
        } catch {
            message = "The schedule was not saved."
        }
    }

    func loadFrame(phoneID: String) async {
        if demo {
            frame = PreviewFrame.jpeg(title: "Spare iPhone")
            return
        }
        guard let client = client() else { return }
        frame = try? await client.latestFrame(phoneID: phoneID)
    }

    private func send(_ body: CommandBody, phoneID: String, optimistic: (inout RemotePhone) -> Void) async {
        update(phoneID, optimistic)
        if demo { return }
        guard let client = client() else { return }
        do {
            _ = try await client.command(body, phoneID: phoneID)
            message = nil
        } catch {
            message = "The spare iPhone did not accept that."
        }
    }

    private func update(_ id: String, _ change: (inout RemotePhone) -> Void) {
        guard let index = phones.firstIndex(where: { $0.id == id }) else { return }
        var phone = phones[index]
        change(&phone)
        phones[index] = phone
    }

    private func client() -> RelayClient? {
        guard let url = RemotePreferences.relayURL(launch: launch) else { return nil }
        let code = RemotePreferences.networkCode(launch: launch)
        guard !code.isEmpty else { return nil }
        return RelayClient(baseURL: url, networkCode: code, transport: AdaptiveRelayTransport())
    }

    private func soundTitle(_ id: String) -> String {
        if let bundled = BundledSound(rawValue: id) { return bundled.title }
        return phones.flatMap(\.music).first { $0.id == id }?.title ?? "Apple Music"
    }
}

extension RemotePhone {
    static let demoSpare = RemotePhone(
        id: "demo-spare",
        name: "Spare iPhone",
        online: true,
        batteryPercent: 80,
        charging: false,
        playback: .idle,
        schedules: [],
        music: [LojoRemote.MusicTrack(id: "music:demo", title: "Night Drive", artist: "Sample")],
        shortcuts: SampleAutomations.shortcuts
    )
}
