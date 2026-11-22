import KodaCore
import ShazamKit
import SwiftUI

/// What Shazam heard.
nonisolated struct HeardSong: Equatable, Sendable {
    var title: String
    var artist: String
    var artworkURL: URL?
}

nonisolated enum Listened: Sendable {
    case heard(HeardSong)
    case noMatch
    case failed(String)
}

/// Listens through the microphone until Shazam knows the song, or gives up. The session is made and
/// used here, off the main actor, so none of ShazamKit's own types cross it.
nonisolated private func listenForSong() async -> Listened {
    // Cancelling the task (the sheet closing) must stop the microphone; `cancel()` is safe from any thread.
    nonisolated(unsafe) let session = SHManagedSession()
    let result = await withTaskCancellationHandler { await session.result() } onCancel: { session.cancel() }
    switch result {
    case .match(let match):
        guard let item = match.mediaItems.first, let title = item.title else { return .noMatch }
        return .heard(HeardSong(title: title, artist: item.artist ?? "", artworkURL: item.artworkURL))
    case .noMatch:
        return .noMatch
    case .error(let error, _):
        return .failed(error.localizedDescription)
    }
}

/// Music Recognition: hears a song and finds it on YouTube Music, so it can be played or kept.
@MainActor
@Observable
final class SongRecognition {
    enum Phase {
        case listening
        /// Heard, and found on YouTube Music.
        case found(HeardSong, Song)
        /// Heard, but YouTube Music has no match for it.
        case notOnYouTubeMusic(HeardSong)
        case noMatch
        case failed(String)
    }

    private(set) var phase = Phase.listening

    func start(music: YouTubeMusic) async {
        phase = .listening
        let listened = await listenForSong()
        guard !Task.isCancelled else { return }
        switch listened {
        case .noMatch:
            phase = .noMatch
        case .failed(let message):
            phase = .failed(message)
        case .heard(let heard):
            let query = "\(heard.title) \(heard.artist)".trimmingCharacters(in: .whitespaces)
            let song = try? await music.search(query, filter: .songs).songs.first
            guard !Task.isCancelled else { return }
            phase = song.map { .found(heard, $0) } ?? .notOnYouTubeMusic(heard)
        }
    }
}

/// The recognition sheet: listening, then the song with what can be done with it.
struct SongRecognitionSheet: View {
    /// Called when a song is played from here, so the music that was paused for listening isn't resumed over it.
    let onPlay: () -> Void
    let onSearch: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recognition = SongRecognition()
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 20) {
            switch recognition.phase {
            case .listening:
                listening
            case .found(let heard, let song):
                result(heard, song: song)
            case .notOnYouTubeMusic(let heard):
                result(heard, song: nil)
            case .noMatch:
                message("Couldn't recognize this song", detail: "Hold your iPhone closer to the music and try again.")
            case .failed(let text):
                message("Music Recognition isn't working", detail: text)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(16)
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
        .task(id: attempt) { await recognition.start(music: app.music) }
        // Going to an artist or album from the menu closes the sheet.
        .onChange(of: app.pendingRoute != nil) { _, pending in if pending { dismiss() } }
    }

    private var listening: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: .circle)
            Text("Listening…").font(.title3.weight(.semibold))
            Text("Hold your iPhone near the music").foregroundStyle(.secondary)
        }
        .sensoryFeedback(.start, trigger: attempt)
    }

    private func result(_ heard: HeardSong, song: Song?) -> some View {
        VStack(spacing: 18) {
            AsyncImage(url: heard.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 132, height: 132)
            .clipShape(.rect(cornerRadius: 14))
            VStack(spacing: 4) {
                Text(heard.title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(heard.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            .multilineTextAlignment(.center)
            if let song {
                HStack(spacing: 12) {
                    Button {
                        onPlay()
                        player.startRadio(from: song)
                        dismiss()
                    } label: {
                        Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 18)
                    }
                    .buttonStyle(.glass)
                    Menu {
                        SongMenuItems(song: song)
                    } label: {
                        Image(systemName: "ellipsis").font(.headline).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("More")
                }
            } else {
                Text("It isn't on YouTube Music.").font(.footnote).foregroundStyle(.secondary)
                Button("Search for It") {
                    onSearch("\(heard.title) \(heard.artist)")
                    dismiss()
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try Again") { attempt += 1 }
                .buttonStyle(.glass)
        }
    }
}
