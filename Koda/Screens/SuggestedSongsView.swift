import KodaCore
import SwiftUI

/// Songs that suit a playlist, from the radios of a few of its songs (see PlaylistSuggester). Tap a
/// song to hear it, the plus to add it to the playlist; Refresh asks about other songs of the playlist.
struct SuggestedSongsView: View {
    let id: UUID

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var phase = Phase.loading
    @State private var added = 0

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
                    Button("Try Again") { Task { await load() } }
                }
            case .loaded(let result):
                list(result)
            }
        }
        .navigationTitle("Suggested Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            }
        }
        .sensoryFeedback(.success, trigger: added)
        .task { await load() }
    }

    private func load() async {
        guard let playlist = library.userPlaylist(id) else { return }
        phase = .loading
        do {
            phase = .loaded(try await PlaylistSuggester.suggest(for: playlist.songs, music: app.music))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// What is worth showing now: not hidden by the listener, and not already added since.
    private func shown(_ result: SuggestionResult) -> [SongSuggestion] {
        let have = Set(library.userPlaylist(id)?.songs.map(\.id) ?? [])
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
                     ? "Add a few songs to this playlist first."
                     : "Nothing new came up. Refresh to ask about other songs of the playlist.")
            } actions: {
                Button("Refresh") { Task { await load() } }
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
                                if library.add([suggestion.song], toPlaylist: id) > 0 { added += 1 }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add to Playlist")
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Based on \(result.seedCount) \(result.seedCount == 1 ? "song" : "songs") of this playlist")
                        .textCase(nil)
                } footer: {
                    Text("Songs that YouTube Music's radio returns for the songs of this playlist; the ones that came up most often are first. It follows style and mood, and doesn't know tempo.")
                }
            }
            .listStyle(.plain)
        }
    }
}
