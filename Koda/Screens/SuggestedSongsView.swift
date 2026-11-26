import KodaCore
import SwiftUI

/// Songs that suit a playlist, from the radios of a few of its songs (see PlaylistSuggester). Tap a
/// song to hear it, the plus to add it to the playlist; Refresh asks about other songs of the playlist.
struct SuggestedSongsView: View {
    /// The playlist to suggest for; nil is Liked Songs.
    var id: UUID?

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var phase = Phase.loading
    @State private var added = 0
    /// What a Refresh must not repeat: the playlist songs already asked about and the suggestions already shown.
    @State private var usedSeeds = Set<String>()
    @State private var seenSongs = Set<String>()

    /// The songs suggestions are for: the playlist's, or the liked ones; nil when the playlist is gone.
    private var current: [Song]? {
        guard let id else { return library.liked }
        return library.userPlaylist(id)?.songs
    }

    private enum Phase {
        case loading
        case loaded(SuggestionResult)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Finding songs that fit…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Find Songs", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load(refresh: false) } }
                }
            case .loaded(let result):
                list(result)
            }
        }
        .navigationTitle("Suggested Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }
            }
        }
        .sensoryFeedback(.success, trigger: added)
        .task { await load(refresh: false) }
    }

    /// A refresh asks about other songs of the playlist and leaves out what was already shown, so what
    /// comes up is new. When nothing new is left, it starts over with everything.
    private func load(refresh: Bool) async {
        guard let songs = current else { return }
        phase = .loading
        let hidden = library.notInterested
        if !refresh {
            usedSeeds = []
            seenSongs = []
        }
        do {
            var result = try await PlaylistSuggester.suggest(
                for: songs, music: app.music, skippingSeeds: usedSeeds, skippingSongs: seenSongs, excluding: hidden.hides)
            if result.suggestions.isEmpty, !seenSongs.isEmpty {
                usedSeeds = []
                seenSongs = []
                result = try await PlaylistSuggester.suggest(for: songs, music: app.music, excluding: hidden.hides)
            }
            usedSeeds.formUnion(result.seedIDs)
            seenSongs.formUnion(result.suggestions.map(\.id))
            phase = .loaded(result)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// What is worth showing now: not hidden by the listener, and not already added since.
    private func shown(_ result: SuggestionResult) -> [SongSuggestion] {
        let have = Set((current ?? []).map(\.id))
        return result.suggestions.filter { !library.isHidden($0.song) && !have.contains($0.song.id) }
    }

    @ViewBuilder
    private func list(_ result: SuggestionResult) -> some View {
        let suggestions = shown(result)
        if suggestions.isEmpty {
            ContentUnavailableView {
                Label("No Suggestions", systemImage: "sparkles")
            } description: {
                Text(result.seedCount == 0
                     ? (id == nil ? "Like a few songs first." : "Add a few songs to this playlist first.")
                     : "Nothing new came up. Refresh to ask about other songs of the playlist.")
            } actions: {
                Button("Refresh") { Task { await load(refresh: true) } }
            }
        } else {
            List {
                Section {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        HStack(spacing: 8) {
                            SongRow(song: suggestion.song) {
                                player.play(suggestions.map(\.song), startAt: index)
                            }
                            Button {
                                if let id {
                                    if library.add([suggestion.song], toPlaylist: id) > 0 { added += 1 }
                                } else {
                                    library.setLiked(suggestion.song, true)
                                    added += 1
                                }
                            } label: {
                                Image(systemName: id == nil ? "heart.circle.fill" : "plus.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(id == nil ? "Like" : "Add to Playlist")
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Based on \(result.seedCount) \(result.seedCount == 1 ? "song" : "songs") of \(id == nil ? "your liked songs" : "this playlist")")
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
        }
    }
}
