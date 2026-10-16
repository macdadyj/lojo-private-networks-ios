import Foundation
import LojoRemote
import UIKit

@MainActor
final class RemoteDeviceRuntime: ObservableObject {
    @Published private(set) var relayStatus = "Connecting…"
    @Published private(set) var playback: PlaybackSnapshot = .idle
    @Published private(set) var batteryLabel = "Battery unknown"
    @Published private(set) var schedules: [SoundSchedule] = []
    @Published private(set) var shortcuts: [NamedShortcut] = SampleAutomations.shortcuts
    @Published private(set) var broadcastReady = false
    let phoneName: String
    private let launch: LaunchOptions
    private var machine: SoundMachine { RemoteIntentBridge.shared.machine }
    private let inbox = FrameInbox()
    private var hold = ScheduleHold()
    private var revision = 0
    private var registered = false
    private var lastPreview = Date.distantPast
    private let phoneID: String

    init(launch: LaunchOptions) {
        self.launch = launch
        phoneName = RemotePreferences.phoneName(launch: launch)
        phoneID = RemotePreferences.phoneID(launch: launch)
        schedules = Self.storedSchedules()
        revision = UserDefaults.standard.integer(forKey: Self.revisionKey)
        broadcastReady = Self.extensionInstalled
    }

    func run() async {
        machine.prepareSession()
        machine.requestMusicAccess()
        UIDevice.current.isBatteryMonitoringEnabled = true
        inbox.setHandler { [weak self] jpeg in
            Task { @MainActor in
                await self?.forward(jpeg)
            }
        }
        inbox.start()
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func tick() async {
        let now = currentDate()
        if machine.consumeSleep(now: now), let active = hold.activeScheduleID {
            hold.activeScheduleID = nil
            hold.suppressedScheduleID = active
        }
        guard let client = client() else {
            relayStatus = "Add the relay address and network code in Settings."
            playback = machine.snapshot(now: now)
            return
        }
        if !registered {
            await register(client)
        }
        var ack: [String] = []
        do {
            let response = try await client.heartbeat(HeartbeatBody(
                batteryPercent: batteryPercent(),
                charging: charging,
                playback: machine.snapshot(now: now),
                music: machine.musicCatalog(),
                shortcuts: RemoteIntentBridge.shared.shortcuts(),
                lastError: machine.snapshot(now: now).message,
                ack: []
            ), phoneID: phoneID)
            if response.scheduleRevision != revision {
                schedules = response.schedules
                revision = response.scheduleRevision
                Self.store(schedules, revision: revision)
            }
            for command in response.commands {
                apply(command, now: now)
                ack.append(command.id)
            }
            relayStatus = "Online"
        } catch {
            relayStatus = "Offline · can't reach the relay"
        }
        let decision = ScheduleEngine.step(schedules: schedules, at: now, calendar: .current, hold: hold)
        hold = decision.1
        switch decision.0 {
        case .start(_, let soundID, let volume):
            machine.setVolume(volume)
            machine.play(soundID: soundID)
        case .stop:
            machine.stop()
        case .none:
            break
        }
        if !ack.isEmpty, let client = client() {
            _ = try? await client.heartbeat(HeartbeatBody(
                batteryPercent: batteryPercent(),
                charging: charging,
                playback: machine.snapshot(now: now),
                music: machine.musicCatalog(),
                shortcuts: RemoteIntentBridge.shared.shortcuts(),
                lastError: machine.snapshot(now: now).message,
                ack: ack
            ), phoneID: phoneID)
        }
        playback = machine.snapshot(now: now)
        shortcuts = RemoteIntentBridge.shared.shortcuts()
        batteryLabel = batteryText()
        if launch.remotePreviewFrame, Date().timeIntervalSince(lastPreview) > 1 {
            lastPreview = Date()
            let jpeg = PreviewFrame.jpeg(title: phoneName)
            if !jpeg.isEmpty {
                ScreenFramePoster().post(jpeg)
            }
        }
    }

    private func register(_ client: RelayClient) async {
        do {
            _ = try await client.register(RegisterBody(
                id: phoneID,
                name: phoneName,
                batteryPercent: batteryPercent(),
                charging: charging,
                schedules: schedules,
                shortcuts: RemoteIntentBridge.shared.shortcuts()
            ))
            registered = true
            relayStatus = "Online"
        } catch {
            relayStatus = "Offline · can't reach the relay"
        }
    }

    private func apply(_ command: RemoteCommand, now: Date) {
        switch command.kind {
        case .play:
            let soundID = command.soundID ?? BundledSound.whiteNoise.rawValue
            machine.play(soundID: soundID)
            if let match = schedules.first(where: { $0.enabled && $0.soundID == soundID }) {
                hold = ScheduleHold(activeScheduleID: match.id)
            } else {
                hold = ScheduleHold()
            }
        case .stop:
            let active = hold.activeScheduleID
            machine.stop()
            hold = ScheduleHold(suppressedScheduleID: active)
        case .setVolume:
            machine.setVolume(command.volume ?? 0.6)
        case .setSleep:
            machine.setSleep(minutes: command.sleepMinutes ?? 0, now: now)
        case .runShortcut:
            let name = command.shortcutName ?? ""
            _ = RemoteIntentBridge.shared.run(name: name, now: now)
            guard let sample = SampleAutomations.match(name: name) else { return }
            switch sample.action {
            case .play(let soundID):
                if let match = schedules.first(where: { $0.enabled && $0.soundID == soundID }) {
                    hold = ScheduleHold(activeScheduleID: match.id)
                } else {
                    hold = ScheduleHold()
                }
            case .stop:
                hold = ScheduleHold(suppressedScheduleID: hold.activeScheduleID)
            }
        }
    }

    func addShortcut(named name: String) {
        RemoteIntentBridge.shared.addName(name)
        shortcuts = RemoteIntentBridge.shared.shortcuts()
    }

    private func forward(_ jpeg: Data) async {
        guard let client = client() else { return }
        if !registered { await register(client) }
        try? await client.postFrame(jpeg, phoneID: phoneID)
    }

    private func client() -> RelayClient? {
        guard let url = RemotePreferences.relayURL(launch: launch) else { return nil }
        let code = RemotePreferences.networkCode(launch: launch)
        guard !code.isEmpty else { return nil }
        return RelayClient(baseURL: url, networkCode: code, transport: AdaptiveRelayTransport())
    }

    private func currentDate() -> Date {
        if let text = launch.remoteNow, let date = ScheduleClock.date(fromHHMM: text) {
            return date
        }
        return Date()
    }

    private func batteryPercent() -> Int? {
        if let override = launch.remoteBattery { return override }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    private var charging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        case .unplugged, .unknown: return false
        @unknown default: return false
        }
    }

    private func batteryText() -> String {
        guard let percent = batteryPercent() else { return "Battery unknown" }
        return charging ? "Battery \(percent)% · charging" : "Battery \(percent)%"
    }

    private static let schedulesKey = "lojo.remote.deviceSchedules"
    private static let revisionKey = "lojo.remote.deviceScheduleRevision"

    private static func storedSchedules() -> [SoundSchedule] {
        guard let data = UserDefaults.standard.data(forKey: schedulesKey) else { return [] }
        return (try? JSONDecoder().decode([SoundSchedule].self, from: data)) ?? []
    }

    private static func store(_ schedules: [SoundSchedule], revision: Int) {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: schedulesKey)
        }
        UserDefaults.standard.set(revision, forKey: revisionKey)
    }

    static var extensionInstalled: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("LojoBroadcast.appex").path)
    }
}
