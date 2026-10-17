import AVFoundation
import Foundation
import LojoRemote
import MediaPlayer

/// Plays bundled sound-machine loops and, when the library allows it, Apple Music.
@MainActor
final class SoundMachine {
    private var player: AVAudioPlayer?
    private let music = MPMusicPlayerController.applicationQueuePlayer
    private var sleepUntil: Date?
    private var volume = 0.6
    private var soundID: String?
    private var title: String?
    private var source: PlaybackSource = .none
    private var message: String?
    private var files: [String: URL] = [:]

    func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    func requestMusicAccess() {
        MPMediaLibrary.requestAuthorization { _ in }
    }

    func play(soundID: String) {
        prepareSession()
        message = nil
        if soundID.hasPrefix("music:") {
            playMusic(soundID: soundID)
            return
        }
        guard let bundled = BundledSound(rawValue: soundID) else {
            message = "That sound is not on this iPhone."
            return
        }
        do {
            music.stop()
            let url = try file(for: bundled)
            let next = try AVAudioPlayer(contentsOf: url)
            next.numberOfLoops = -1
            next.volume = Float(volume)
            next.prepareToPlay()
            next.play()
            player = next
            self.soundID = bundled.rawValue
            title = bundled.title
            source = .bundled
        } catch {
            message = "Could not play \(bundled.title)."
        }
    }

    func stop() {
        player?.stop()
        player = nil
        music.stop()
        soundID = nil
        title = nil
        source = .none
        sleepUntil = nil
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        player?.volume = Float(volume)
        if source == .appleMusic {
            message = "Apple Music follows this iPhone's volume buttons."
        }
    }

    func note(_ text: String?) {
        message = text
    }

    func playPlaylist(named name: String) {
        prepareSession()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Name the Apple Music playlist."
            return
        }
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            requestMusicAccess()
            message = "Allow Music access on this iPhone, then try the playlist again."
            return
        }
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: trimmed,
            forProperty: MPMediaPlaylistPropertyName,
            comparisonType: .equalTo
        ))
        guard let playlist = query.collections?.first else {
            message = "No Apple Music playlist named \(trimmed) is on this iPhone."
            return
        }
        // Xcode 26's SDK returns a non-optional list. Xcode 16.4 still returns an optional.
        #if swift(>=6.2)
        let songs = playlist.items
        #else
        let songs = playlist.items ?? []
        #endif
        guard !songs.isEmpty else {
            message = "No Apple Music playlist named \(trimmed) is on this iPhone."
            return
        }
        player?.stop()
        player = nil
        music.stop()
        music.setQueue(with: playlist)
        music.play()
        soundID = "playlist:\(trimmed)"
        title = playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String ?? trimmed
        source = .appleMusic
        message = "Apple Music follows this iPhone's volume buttons."
    }

    func setSleep(minutes: Int, now: Date) {
        if minutes <= 0 {
            sleepUntil = nil
            return
        }
        sleepUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Stops playback when the sleep deadline has passed. Returns true when it stopped.
    func consumeSleep(now: Date) -> Bool {
        guard let sleepUntil, now >= sleepUntil else { return false }
        stop()
        message = "Sleep timer ended."
        return true
    }

    func snapshot(now: Date) -> PlaybackSnapshot {
        let remaining: Int?
        if let sleepUntil {
            remaining = max(0, Int(sleepUntil.timeIntervalSince(now).rounded(.down)))
        } else {
            remaining = nil
        }
        let playing = source == .appleMusic ? music.playbackState == .playing : (player?.isPlaying ?? false)
        return PlaybackSnapshot(
            playing: playing,
            soundID: soundID,
            title: title,
            volume: volume,
            sleepRemainingSec: remaining,
            source: playing ? source : .none,
            message: message
        )
    }

    func musicCatalog() -> [LojoRemote.MusicTrack] {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return [] }
        let items = MPMediaQuery.songs().items ?? []
        return items.prefix(40).map { item in
            LojoRemote.MusicTrack(
                id: "music:\(item.persistentID)",
                title: item.title ?? "Untitled",
                artist: item.artist ?? ""
            )
        }
    }

    private func playMusic(soundID: String) {
        let raw = soundID.dropFirst("music:".count)
        guard let persistent = UInt64(raw) else {
            message = "That Apple Music song is not on this iPhone."
            return
        }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: persistent),
            forProperty: MPMediaItemPropertyPersistentID
        ))
        guard let item = query.items?.first else {
            message = "That Apple Music song is not on this iPhone."
            return
        }
        player?.stop()
        player = nil
        music.stop()
        music.setQueue(with: query)
        music.play()
        self.soundID = soundID
        title = item.title ?? "Apple Music"
        source = .appleMusic
        message = "Apple Music follows this iPhone's volume buttons."
    }

    private func file(for sound: BundledSound) throws -> URL {
        if let cached = files[sound.rawValue] { return cached }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lojo-\(sound.rawValue).wav")
        try SoundWave.wav(for: sound).write(to: url, options: .atomic)
        files[sound.rawValue] = url
        return url
    }
}
