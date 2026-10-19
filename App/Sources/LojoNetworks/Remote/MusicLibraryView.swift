import LojoRemote
import SwiftUI
import UIKit

struct MusicLibraryView: View {
    let phoneID: String
    var startScope = "sections"
    @EnvironmentObject private var remote: RemoteControllerStore
    @State private var query = ""
    @State private var scope = "sections"
    @State private var parent = ""
    @State private var started = false

    private var phone: RemotePhone? { remote.phones.first { $0.id == phoneID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Search the library", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .accessibilityIdentifier("remote.library.search")
                    .onSubmit {
                        Task { await show("search", parent: "") }
                    }
                if scope == "sections" {
                    section("Recently Played", scope: "recent", systemImage: "clock")
                    section("Playlists", scope: "playlists", systemImage: "music.note.list")
                    section("Artists", scope: "artists", systemImage: "person.2")
                    section("Albums", scope: "albums", systemImage: "square.stack")
                    section("Songs", scope: "songs", systemImage: "music.note")
                } else {
                    Button("All sections") { scope = "sections" }
                        .accessibilityIdentifier("remote.library.sections")
                    if phone?.music.isEmpty != false {
                        EmptyStateCard(
                            systemImage: "music.note",
                            title: "Nothing in this list",
                            message: "Allow Music access on the spare phone, or try another section. Results arrive one page at a time.",
                            primary: nil,
                            secondary: nil
                        )
                    }
                    ForEach(phone?.music ?? []) { track in
                        Button {
                            Task { await open(track) }
                        } label: {
                            HStack(spacing: 12) {
                                artwork(track)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if !track.artist.isEmpty {
                                        Text(track.artist)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("remote.library.item.\(track.id)")
                    }
                    if let page = phone?.music.first?.page, let count = phone?.music.first?.pageCount, page + 1 < count {
                        Button("Next page") {
                            Task { await show(scope, parent: parent, page: page + 1) }
                        }
                        .accessibilityIdentifier("remote.library.next-page")
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(scope == "sections" ? "Music" : scope.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !started else { return }
            started = true
            if startScope != "sections" {
                await show(startScope, parent: "")
            }
        }
    }

    private func section(_ title: String, scope: String, systemImage: String) -> some View {
        Button {
            Task { await show(scope, parent: "") }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remote.library.\(scope)")
    }

    private func show(_ scope: String, parent: String, page: Int = 0) async {
        self.scope = scope
        self.parent = parent
        await remote.browse(phoneID: phoneID, scope: scope, page: page, parent: parent, query: query)
    }

    private func open(_ track: MusicTrack) async {
        switch track.kind ?? "" {
        case "song":
            remote.selectedSoundID = track.id
            await remote.play(phoneID: phoneID)
        case "playlist", "artist", "album":
            await show("songs", parent: track.id)
        default:
            await show("songs", parent: track.id)
        }
    }

    @ViewBuilder
    private func artwork(_ track: MusicTrack) -> some View {
        if let text = track.artworkJPEG, let data = Data(base64Encoded: text), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: icon(track.kind))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }

    private func icon(_ kind: String?) -> String {
        switch kind {
        case "playlist": return "music.note.list"
        case "artist": return "person.2"
        case "album": return "square.stack"
        case "song": return "music.note"
        default: return "music.note"
        }
    }
}
