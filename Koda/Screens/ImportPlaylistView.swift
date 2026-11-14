import KodaCore
import SwiftUI

/// One import from a public Spotify or SoundCloud playlist link: reads the playlist, finds each
/// song on YouTube Music and makes a playlist of the ones found.
@Observable
final class PlaylistImportModel {
    struct Finished {
        var playlistID: UUID
        var name: String
        var found: Int
        var total: Int
        var missing: [ImportedTrack]
        var isPartial: Bool
    }

    enum Phase {
        case idle
        case reading
        case matching(done: Int, total: Int)
        case finished(Finished)
        case failed(String)
    }

    var phase = Phase.idle
    private var task: Task<Void, Never>?

    var isWorking: Bool {
        switch phase {
        case .reading, .matching: true
        default: false
        }
    }

    var isFinished: Bool {
        if case .finished = phase { true } else { false }
    }

    func start(_ text: String, source: PlaylistSource, music: YouTubeMusic, library: Library) {
        guard let link = PlaylistLink.parse(text, as: source) else {
            phase = .failed(PlaylistImportError.notALink(source).localizedDescription)
            return
        }
        phase = .reading
        task = Task { [weak self] in
            do {
                let result = try await PlaylistImporter(music: music).run(link) { done, total in
                    Task { @MainActor in self?.progress(done, total) }
                }
                guard !result.songs.isEmpty else {
                    self?.phase = .failed("None of the \(result.total) songs could be found on YouTube Music.")
                    return
                }
                let playlist = library.createPlaylist(named: result.name, songs: result.songs)
                self?.phase = .finished(Finished(playlistID: playlist.id, name: playlist.name, found: result.songs.count,
                                                 total: result.total, missing: result.missing, isPartial: result.isPartial))
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        if isWorking { phase = .idle }
    }

    private func progress(_ done: Int, _ total: Int) {
        // Updates can land out of order; the count only goes up.
        if case .matching(let current, _) = phase, current > done { return }
        guard isWorking else { return }
        phase = .matching(done: done, total: total)
    }
}

struct ImportPlaylistView: View {
    let source: PlaylistSource
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model = PlaylistImportModel()
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .idle:
                    linkSection(error: nil)
                case .failed(let message):
                    linkSection(error: message)
                case .reading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Reading the playlist…")
                        }
                    }
                case .matching(let done, let total):
                    Section {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("Finding songs on YouTube Music: \(done) of \(total)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("This takes a moment. Keep Koda open.")
                    }
                case .finished(let finished):
                    finishedSections(finished)
                }
            }
            .navigationTitle("Import from \(source.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isFinished ? "Done" : "Cancel") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(model.isWorking)
        }
    }

    private var instructions: String {
        switch source {
        case .spotify:
            "The playlist has to be public. In Spotify open it, tap ···, then Share and Copy link, and paste the link here. Spotify shows Koda only the first 100 songs of a playlist."
        case .soundCloud:
            "The playlist has to be public. In SoundCloud open it, tap Share and Copy link, and paste the link here. SoundCloud's pages change without notice, so this can stop working."
        }
    }

    private func linkSection(error: String?) -> some View {
        Group {
            Section {
                HStack {
                    TextField("Playlist link", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(start)
                    PasteButton(payloadType: String.self) { strings in
                        if let pasted = strings.first { text = pasted }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                Button("Import Playlist", action: start)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text(instructions)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func finishedSections(_ finished: PlaylistImportModel.Finished) -> some View {
        Section {
            Label(finished.name, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("\(finished.found) of \(finished.total) songs were added to a new playlist.")
            if finished.isPartial {
                Text("\(source.name) shows only the first 100 songs of a playlist, so a longer one is cut short.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Open Playlist") {
                app.open(.userPlaylist(finished.playlistID))
                dismiss()
            }
        }
        if !finished.missing.isEmpty {
            Section("Not found (\(finished.missing.count))") {
                ForEach(Array(finished.missing.enumerated()), id: \.offset) { _, track in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                        if !track.artist.isEmpty {
                            Text(track.artist).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func start() {
        model.start(text, source: source, music: app.music, library: library)
    }
}
