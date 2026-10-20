import Foundation

public enum RemoteHelpCopy {
    public static let productName = "iPhone Remote Controller"
    public static let limitsShort = "Cannot read iMessages, move icons, or inject taps."
    public static let limits = """
    iPhone Remote Controller cannot read your iMessages, move Home Screen icons, or inject taps. iOS does not allow any of those, and this app does not try.

    Both phones use the site gateway you already paired. There is no separate relay address to type.

    What does travel across your private network: play and stop, the sound you pick, volume for the built-in sounds, a sleep timer, and schedules such as white noise from 8:00 PM to 6:00 AM. Schedules run on the spare phone while Control mode is on. A sound that is playing continues with the screen locked, including the stop time. With nothing playing, iOS may suspend the app soon after the screen locks, and the controlling phone shows Not reachable. A start time fires while Control mode is still running. iOS will not launch it after the app is closed from the app switcher.

    Apple Music uses the spare iPhone's own volume buttons. iOS does not let another phone set the system volume. Built-in sounds use the volume slider.

    Shortcuts and Siri on the spare iPhone can play a sound, stop, set the built-in volume, play an Apple Music playlist, start a sleep timer, and report status. Two samples ship with the app: Bedtime white noise, and Morning off.

    Your other phone can run a Shortcut by the name listed here. Samples run inside this app. A Shortcut you built in the Shortcuts app is opened with the shortcuts link, and only while iPhone Remote Controller is on screen or a sound is already playing. iOS will not open that link after a force-quit, and a Shortcut that asks a question may not finish in the background. This app cannot list every Shortcut on the iPhone or see the actions inside one. It still cannot read iMessages, move icons, or inject taps.
    """
}

public struct NamedShortcut: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var builtin: Bool
    public var summary: String

    public init(name: String, builtin: Bool, summary: String) {
        self.name = name
        self.builtin = builtin
        self.summary = summary
    }

    public var id: String { name }

    public var accessibilityID: String {
        let slug = name.lowercased().unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return "remote.shortcut.\(slug)"
    }
}

public enum SampleAction: Equatable, Sendable {
    case play(soundID: String)
    case stop
}

public struct SampleAutomation: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var action: SampleAction

    public var shortcut: NamedShortcut {
        NamedShortcut(name: name, builtin: true, summary: summary)
    }
}

public enum SampleAutomations {
    public static let bedtime = SampleAutomation(
        id: "bedtime-white-noise",
        name: "Bedtime white noise",
        summary: "Play white noise at bedtime.",
        action: .play(soundID: BundledSound.whiteNoise.rawValue)
    )
    public static let morning = SampleAutomation(
        id: "morning-off",
        name: "Morning off",
        summary: "Stop the sound in the morning.",
        action: .stop
    )
    public static let all = [bedtime, morning]
    public static var shortcuts: [NamedShortcut] { all.map(\.shortcut) }
    public static var bedtimeSchedule: SoundSchedule { .overnightWhiteNoise(id: bedtime.id) }

    public static func match(name: String) -> SampleAutomation? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}

public enum ShortcutAvailability: Equatable, Sendable {
    /// A shipped sample. This app performs it directly.
    case inApp
    /// A name the user added. Open it with the Shortcuts app.
    case shortcutsURL
    /// The phone is suspended, so iOS will not open the Shortcuts app.
    case unavailable
}

public enum ShortcutLink {
    public static func availability(name: String, foreground: Bool, audioPlaying: Bool) -> ShortcutAvailability {
        if SampleAutomations.match(name: name) != nil { return .inApp }
        if foreground || audioPlaying { return .shortcutsURL }
        return .unavailable
    }

    /// `shortcuts://run-shortcut?name=`. Rejects blank names and extra query characters.
    public static func runURL(name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        let blocked = CharacterSet(charactersIn: "&#?=\n\r")
        guard trimmed.unicodeScalars.allSatisfy({ !blocked.contains($0) }) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)"),
              url.host == "run-shortcut" || url.host == nil else { return nil }
        return url
    }
}

public enum BundledSound: String, CaseIterable, Codable, Sendable, Identifiable {
    case whiteNoise = "white-noise"
    case pinkNoise = "pink-noise"
    case brownNoise = "brown-noise"
    case rain
    case fan

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .whiteNoise: return "White Noise"
        case .pinkNoise: return "Pink Noise"
        case .brownNoise: return "Brown Noise"
        case .rain: return "Rain"
        case .fan: return "Fan"
        }
    }

    public var systemImage: String {
        switch self {
        case .whiteNoise: return "waveform"
        case .pinkNoise: return "waveform.path"
        case .brownNoise: return "waveform.path.ecg"
        case .rain: return "cloud.rain"
        case .fan: return "fanblades"
        }
    }
}

public enum PlaybackSource: String, Codable, Sendable {
    case bundled
    case appleMusic = "apple-music"
    case none
}

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public var playing: Bool
    public var soundID: String?
    public var title: String?
    public var volume: Double
    public var sleepRemainingSec: Int?
    public var source: PlaybackSource
    public var message: String?

    public init(
        playing: Bool,
        soundID: String? = nil,
        title: String? = nil,
        volume: Double,
        sleepRemainingSec: Int? = nil,
        source: PlaybackSource,
        message: String? = nil
    ) {
        self.playing = playing
        self.soundID = soundID
        self.title = title
        self.volume = volume
        self.sleepRemainingSec = sleepRemainingSec
        self.source = source
        self.message = message
    }

    public static let idle = PlaybackSnapshot(playing: false, volume: 0.6, source: .none)
}

public struct MusicTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var subtitle: String?
    public var kind: String?
    public var artworkJPEG: String?
    public var scope: String?
    public var page: Int?
    public var pageCount: Int?

    public init(
        id: String,
        title: String,
        artist: String,
        subtitle: String? = nil,
        kind: String? = nil,
        artworkJPEG: String? = nil,
        scope: String? = nil,
        page: Int? = nil,
        pageCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.subtitle = subtitle
        self.kind = kind
        self.artworkJPEG = artworkJPEG
        self.scope = scope
        self.page = page
        self.pageCount = pageCount
    }
}

/// A library browse request carried on the existing play command as `library:scope:page:parent:query`.
/// The site gateway already forwards that command. It does not need a new route.
public struct LibraryRequest: Equatable, Sendable {
    public var scope: String
    public var page: Int
    public var parent: String
    public var query: String

    public init(scope: String, page: Int, parent: String = "", query: String = "") {
        self.scope = scope
        self.page = page
        self.parent = parent
        self.query = query
    }

    public var soundID: String {
        let parentText = parent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let queryText = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return "library:\(scope):\(page):\(parentText):\(queryText)"
    }

    public static func parse(_ soundID: String) -> LibraryRequest? {
        guard soundID.hasPrefix("library:") else { return nil }
        let parts = soundID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, let page = Int(parts[2]) else { return nil }
        let parent = parts[3].removingPercentEncoding ?? parts[3]
        let query = parts.dropFirst(4).joined(separator: ":").removingPercentEncoding ?? ""
        let scope = parts[1]
        guard ["recent", "playlists", "artists", "albums", "songs", "search", "queue"].contains(scope) else { return nil }
        return LibraryRequest(scope: scope, page: max(0, page), parent: parent, query: query)
    }
}

public enum LibraryPageSlice {
    public static let pageSize = 24

    public static func slice<T>(_ items: [T], page: Int) -> (page: Int, pageCount: Int, items: [T]) {
        if items.isEmpty { return (0, 0, []) }
        let pageCount = (items.count + pageSize - 1) / pageSize
        let safe = min(max(0, page), pageCount - 1)
        let start = safe * pageSize
        let end = min(items.count, start + pageSize)
        return (safe, pageCount, Array(items[start..<end]))
    }
}

public enum DemoLibrary {
    public static let all: [MusicTrack] = [
        MusicTrack(id: "playlist:1", title: "Road Trips", artist: "", subtitle: "Playlist", kind: "playlist"),
        MusicTrack(id: "artist:1", title: "Sample", artist: "Sample", subtitle: "Artist", kind: "artist"),
        MusicTrack(id: "album:1", title: "Night Drive", artist: "Sample", subtitle: "Album", kind: "album"),
        MusicTrack(id: "music:demo", title: "Night Drive", artist: "Sample", subtitle: "Song", kind: "song"),
        MusicTrack(id: "music:demo2", title: "Dawn", artist: "Sample", subtitle: "Song", kind: "song"),
    ]

    public static func page(scope: String, page: Int, parent: String, query: String) -> [MusicTrack] {
        let wanted: [MusicTrack]
        switch scope {
        case "playlists":
            wanted = all.filter { $0.kind == "playlist" }
        case "artists":
            wanted = all.filter { $0.kind == "artist" }
        case "albums":
            wanted = all.filter { $0.kind == "album" }
        case "recent":
            wanted = all.filter { $0.kind == "song" }
        case "queue":
            wanted = all.filter { $0.kind == "song" }
        case "search":
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            wanted = all.filter {
                needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle) || $0.artist.localizedCaseInsensitiveContains(needle)
            }
        case "songs":
            wanted = all.filter { $0.kind == "song" && (parent.isEmpty || $0.id.hasPrefix("music:")) }
        default:
            wanted = []
        }
        let sliced = LibraryPageSlice.slice(wanted, page: page)
        return sliced.items.map { item in
            var copy = item
            copy.scope = scope
            copy.page = sliced.page
            copy.pageCount = sliced.pageCount
            return copy
        }
    }
}

public struct SoundSchedule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var soundID: String
    public var startMinutes: Int
    public var stopMinutes: Int
    public var enabled: Bool
    public var volume: Double

    public init(id: String, soundID: String, startMinutes: Int, stopMinutes: Int, enabled: Bool, volume: Double) {
        self.id = id
        self.soundID = soundID
        self.startMinutes = startMinutes
        self.stopMinutes = stopMinutes
        self.enabled = enabled
        self.volume = volume
    }

    public static func overnightWhiteNoise(id: String = "overnight-white-noise") -> SoundSchedule {
        SoundSchedule(
            id: id,
            soundID: BundledSound.whiteNoise.rawValue,
            startMinutes: 20 * 60,
            stopMinutes: 6 * 60,
            enabled: true,
            volume: 0.6
        )
    }

    public var windowLabel: String {
        "\(ScheduleClock.label(minutes: startMinutes)) – \(ScheduleClock.label(minutes: stopMinutes))"
    }

    public var soundTitle: String {
        if let bundled = BundledSound(rawValue: soundID) { return bundled.title }
        return soundID
    }
}

public struct RemotePhone: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var online: Bool
    public var batteryPercent: Int?
    public var charging: Bool
    public var playback: PlaybackSnapshot?
    public var schedules: [SoundSchedule]
    public var scheduleRevision: Int
    public var music: [MusicTrack]
    public var shortcuts: [NamedShortcut]
    public var lastError: String?

    public init(
        id: String,
        name: String,
        online: Bool,
        batteryPercent: Int?,
        charging: Bool,
        playback: PlaybackSnapshot? = nil,
        schedules: [SoundSchedule] = [],
        scheduleRevision: Int = 0,
        music: [MusicTrack] = [],
        shortcuts: [NamedShortcut] = [],
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.online = online
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.playback = playback
        self.schedules = schedules
        self.scheduleRevision = scheduleRevision
        self.music = music
        self.shortcuts = shortcuts
        self.lastError = lastError
    }

    public var batteryLabel: String {
        guard let batteryPercent else { return "Battery unknown" }
        return charging ? "Battery \(batteryPercent)% · charging" : "Battery \(batteryPercent)%"
    }

    public var statusLabel: String { online ? "Online" : "Offline" }
}

public struct RemoteCommand: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case play
        case stop
        case setVolume
        case setSleep
        case runShortcut
    }

    public var id: String
    public var seq: Int
    public var kind: Kind
    public var soundID: String?
    public var volume: Double?
    public var sleepMinutes: Int?
    public var shortcutName: String?

    public init(
        id: String,
        seq: Int,
        kind: Kind,
        soundID: String? = nil,
        volume: Double? = nil,
        sleepMinutes: Int? = nil,
        shortcutName: String? = nil
    ) {
        self.id = id
        self.seq = seq
        self.kind = kind
        self.soundID = soundID
        self.volume = volume
        self.sleepMinutes = sleepMinutes
        self.shortcutName = shortcutName
    }
}

public enum ScheduleClock {
    public static func minutes(from date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return normalize((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    public static func normalize(_ minutes: Int) -> Int {
        let day = 24 * 60
        let wrapped = minutes % day
        return wrapped >= 0 ? wrapped : wrapped + day
    }

    public static func label(minutes: Int) -> String {
        let value = normalize(minutes)
        let hour24 = value / 60
        let minute = value % 60
        let period = hour24 >= 12 ? "PM" : "AM"
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, minute, period)
    }

    /// `HH:mm` in the given calendar, on the same civil day as `now`.
    public static func date(fromHHMM text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }
}

public struct ScheduleHold: Equatable, Sendable {
    public var activeScheduleID: String?
    public var suppressedScheduleID: String?

    public init(activeScheduleID: String? = nil, suppressedScheduleID: String? = nil) {
        self.activeScheduleID = activeScheduleID
        self.suppressedScheduleID = suppressedScheduleID
    }
}

public enum ScheduleAction: Equatable, Sendable {
    case start(scheduleID: String, soundID: String, volume: Double)
    case stop(scheduleID: String)
    case none
}

public enum ScheduleEngine {
    public static func contains(minute: Int, start: Int, stop: Int) -> Bool {
        let minute = ScheduleClock.normalize(minute)
        let start = ScheduleClock.normalize(start)
        let stop = ScheduleClock.normalize(stop)
        if start == stop { return false }
        if start < stop { return minute >= start && minute < stop }
        return minute >= start || minute < stop
    }

    public static func step(
        schedules: [SoundSchedule],
        at date: Date,
        calendar: Calendar = .current,
        hold: ScheduleHold
    ) -> (ScheduleAction, ScheduleHold) {
        let minute = ScheduleClock.minutes(from: date, calendar: calendar)
        let match = schedules.first {
            $0.enabled && contains(minute: minute, start: $0.startMinutes, stop: $0.stopMinutes)
        }
        if let match {
            if hold.suppressedScheduleID == match.id || hold.activeScheduleID == match.id {
                return (.none, hold)
            }
            return (
                .start(scheduleID: match.id, soundID: match.soundID, volume: match.volume),
                ScheduleHold(activeScheduleID: match.id, suppressedScheduleID: nil)
            )
        }
        var cleared = hold
        cleared.suppressedScheduleID = nil
        if let active = hold.activeScheduleID {
            cleared.activeScheduleID = nil
            return (.stop(scheduleID: active), cleared)
        }
        return (.none, cleared)
    }
}
