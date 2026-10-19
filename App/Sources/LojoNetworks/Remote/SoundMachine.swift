import AVFoundation
import Foundation
import LojoRemote
import MediaPlayer
import UIKit

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
    private var libraryRequest = LibraryRequest(scope: "songs", page: 0)

    func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    func requestMusicAccess() {
        MPMediaLibrary.requestAuthorization { _ in }
    }

    func play(soundID: String) {
        if soundID == "transport:next" {
            skip(next: true)
            return
        }
        if soundID == "transport:previous" {
            skip(next: false)
            return
        }
        if let request = LibraryRequest.parse(soundID) {
            libraryRequest = request
            message = nil
            return
        }
        prepareSession()
        message = nil
        if soundID.hasPrefix("playlist:") {
            playPlaylist(id: soundID)
            return
        }
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
        let request = libraryRequest
        let all = libraryItems(request)
        let sliced = LibraryPageSlice.slice(all, page: request.page)
        return sliced.items.map { item in
            var copy = item
            copy.scope = request.scope
            copy.page = sliced.page
            copy.pageCount = sliced.pageCount
            return copy
        }
    }

    private func skip(next: Bool) {
        guard source == .appleMusic else {
            message = "Next and previous move through the Music library."
            return
        }
        if next { music.skipToNextItem() } else { music.skipToPreviousItem() }
        if let item = music.nowPlayingItem {
            title = item.title ?? title
            soundID = "music:\(item.persistentID)"
        }
    }

    private func libraryItems(_ request: LibraryRequest) -> [MusicTrack] {
        switch request.scope {
        case "recent":
            return songs(matching: "").filter { $0.subtitle == "recent" }
        case "playlists":
            return collections(MPMediaQuery.playlists(), kind: "playlist", prefix: "playlist")
        case "artists":
            return collections(MPMediaQuery.artists(), kind: "artist", prefix: "artist")
        case "albums":
            return collections(MPMediaQuery.albums(), kind: "album", prefix: "album")
        case "queue":
            guard let item = music.nowPlayingItem, item.albumPersistentID != 0 else { return [] }
            return songs(matching: "").filter { ($0.subtitle ?? "").contains("album:\(item.albumPersistentID)") }
        case "search":
            return songs(matching: request.query)
        case "songs":
            if request.parent.hasPrefix("playlist:") {
                return playlistSongs(id: request.parent)
            }
            if request.parent.hasPrefix("album:") || request.parent.hasPrefix("artist:") {
                return songs(matching: "").filter { ($0.subtitle ?? "").contains(request.parent) }
            }
            return songs(matching: "")
        default:
            return []
        }
    }

    private func songs(matching query: String) -> [MusicTrack] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = (MPMediaQuery.songs().items ?? []).filter { item in
            guard !needle.isEmpty else { return true }
            let title = item.title ?? ""
            let artist = item.artist ?? ""
            return title.localizedCaseInsensitiveContains(needle) || artist.localizedCaseInsensitiveContains(needle)
        }
        let recent = requestIsRecent
        let sorted = recent
            ? items.sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }.filter { $0.lastPlayedDate != nil }
            : items
        return sorted.map { songTrack($0, recent: recent) }
    }

    private var requestIsRecent: Bool { libraryRequest.scope == "recent" }

    private func songTrack(_ item: MPMediaItem, recent: Bool) -> MusicTrack {
        MusicTrack(
            id: "music:\(item.persistentID)",
            title: item.title ?? "Untitled",
            artist: item.artist ?? "",
            subtitle: recent ? "recent" : "album:\(item.albumPersistentID) artist:\(item.artistPersistentID)",
            kind: "song",
            artworkJPEG: artworkJPEG(item.artwork)
        )
    }

    private func collections(_ query: MPMediaQuery, kind: String, prefix: String) -> [MusicTrack] {
        (query.collections ?? []).map { collection in
            let name = collection.value(forProperty: nameProperty(kind)) as? String ?? "Untitled"
            let id = collection.persistentID
            return MusicTrack(id: "\(prefix):\(id)", title: name, artist: "", subtitle: kind.capitalized, kind: kind, artworkJPEG: artworkJPEG(collection.representativeItem?.artwork))
        }
    }

    private func nameProperty(_ kind: String) -> String {
        switch kind {
        case "playlist": return MPMediaPlaylistPropertyName
        case "artist": return MPMediaItemPropertyArtist
        case "album": return MPMediaItemPropertyAlbumTitle
        default: return MPMediaItemPropertyTitle
        }
    }

    private func playlistSongs(id: String) -> [MusicTrack] {
        let raw = id.dropFirst("playlist:".count)
        guard let persistent = UInt64(raw) else { return [] }
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: persistent), forProperty: MPMediaPlaylistPropertyPersistentID))
        guard let playlist = query.collections?.first else { return [] }
        #if swift(>=6.2)
        let songs = playlist.items
        #else
        let songs = playlist.items ?? []
        #endif
        return songs.map { songTrack($0, recent: false) }
    }

    private func playPlaylist(id: String) {
        prepareSession()
        let raw = id.dropFirst("playlist:".count)
        guard let persistent = UInt64(raw), MPMediaLibrary.authorizationStatus() == .authorized else {
            message = "Allow Music access on this phone, then try again."
            return
        }
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: persistent), forProperty: MPMediaPlaylistPropertyPersistentID))
        guard let playlist = query.collections?.first else {
            message = "That playlist is not on this phone."
            return
        }
        player?.stop()
        player = nil
        music.stop()
        music.setQueue(with: playlist)
        music.play()
        soundID = id
        title = playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String ?? "Playlist"
        source = .appleMusic
        message = "Music follows this phone's volume buttons."
    }

    private func artworkJPEG(_ artwork: MPMediaItemArtwork?) -> String? {
        guard let image = artwork?.image(at: CGSize(width: 60, height: 60)),
              let data = image.jpegData(compressionQuality: 0.5),
              data.count <= 24_000 else { return nil }
        return data.base64EncodedString()
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
