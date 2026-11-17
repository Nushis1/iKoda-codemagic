import Foundation

/// A song that fits a playlist, and how many of the playlist's songs pointed at it.
public struct SongSuggestion: Identifiable, Sendable {
    public let song: Song
    /// How many of the radios that were asked agreed on this song. More is a better fit.
    public let votes: Int

    public var id: String { song.id }
}

public struct SuggestionResult: Sendable {
    public let suggestions: [SongSuggestion]
    /// How many songs of the playlist were used to find them.
    public let seedCount: Int
    /// The playlist songs that were asked about, so that the next try can ask about others.
    public let seedIDs: [String]
}

/// Songs that suit a playlist: a few of its songs are picked, YouTube Music's radio is asked for what
/// goes with each, and the songs that come up most often win. That follows the style and the mood as
/// YouTube Music hears them; tempo is not known to it, so it only shows through the radios.
public enum PlaylistSuggester {
    /// The songs a new pick is made from: those not asked about last time, unless too few are left.
    static func seedPool(_ playlist: [Song], skipping used: Set<String>, count: Int) -> [Song] {
        let fresh = playlist.filter { !used.contains($0.id) }
        return fresh.count >= min(count, playlist.count) ? fresh : playlist
    }

    /// A few of the playlist's songs to ask about; different ones each time.
    public static func pickSeeds<G: RandomNumberGenerator>(from songs: [Song], count: Int, using generator: inout G) -> [Song] {
        Array(songs.shuffled(using: &generator).prefix(max(0, count)))
    }

    private struct Candidate {
        var song: Song
        var votes = 0
        /// Where the best radio had it: nearer the front is a closer match.
        var bestPosition: Int
        /// The order in which it was first met, to keep ties steady.
        var order: Int
    }

    /// Ranks what the radios returned: most agreed on first, then the closest. A song the playlist
    /// already has, in any upload, is left out, and so is a second upload of a suggestion.
    public static func rank(radios: [[Song]], playlist: [Song], limit: Int = 40) -> [SongSuggestion] {
        let owned = Set(playlist.map(\.id))
        let ownedKeys = playlist.map { DuplicateFinder.keys(for: $0) }

        var candidates: [String: Candidate] = [:]
        var order = 0
        for radio in radios {
            var counted = Set<String>()
            for (position, song) in radio.enumerated() where !owned.contains(song.id) {
                if var candidate = candidates[song.id] {
                    if counted.insert(song.id).inserted { candidate.votes += 1 }
                    candidate.bestPosition = min(candidate.bestPosition, position)
                    candidates[song.id] = candidate
                } else {
                    counted.insert(song.id)
                    candidates[song.id] = Candidate(song: song, votes: 1, bestPosition: position, order: order)
                    order += 1
                }
            }
        }

        let ranked = candidates.values.sorted {
            if $0.votes != $1.votes { return $0.votes > $1.votes }
            if $0.bestPosition != $1.bestPosition { return $0.bestPosition < $1.bestPosition }
            return $0.order < $1.order
        }

        var accepted: [SongSuggestion] = []
        var acceptedKeys: [DuplicateFinder.Keys] = []
        for candidate in ranked {
            let keys = DuplicateFinder.keys(for: candidate.song)
            let isTwin = { (other: DuplicateFinder.Keys) in
                !keys.core.isEmpty && keys.core == other.core && DuplicateFinder.sameArtist(keys, other)
            }
            if ownedKeys.contains(where: isTwin) || acceptedKeys.contains(where: isTwin) { continue }
            accepted.append(SongSuggestion(song: candidate.song, votes: candidate.votes))
            acceptedKeys.append(keys)
            if accepted.count == limit { break }
        }
        return accepted
    }

    /// Asks the radios of a few of the playlist's songs, at the same time, and ranks what comes back.
    /// A radio that fails is skipped; it throws only when none answered.
    ///
    /// - Parameters:
    ///   - skippingSeeds: playlist songs that were asked about before; others are chosen if enough remain.
    ///   - skippingSongs: suggestions that were shown before, so a refresh brings new ones.
    public static func suggest(for playlist: [Song], music: YouTubeMusic, seedCount: Int = 5, limit: Int = 40,
                               skippingSeeds: Set<String> = [], skippingSongs: Set<String> = []) async throws -> SuggestionResult {
        guard !playlist.isEmpty else { return SuggestionResult(suggestions: [], seedCount: 0, seedIDs: []) }
        var generator = SystemRandomNumberGenerator()
        let seeds = pickSeeds(from: seedPool(playlist, skipping: skippingSeeds, count: seedCount),
                              count: seedCount, using: &generator)
        var radios: [[Song]] = []
        var failure: Error?
        await withTaskGroup(of: Result<[Song], Error>.self) { group in
            for seed in seeds {
                group.addTask {
                    do {
                        return .success(try await music.radio(for: seed.id).songs)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let songs): radios.append(songs)
                case .failure(let error): failure = error
                }
            }
        }
        if radios.isEmpty, let failure { throw failure }
        // Ranked deep, then the ones shown before are dropped: what is left starts where the last try ended.
        let fresh = rank(radios: radios, playlist: playlist, limit: 400).filter { !skippingSongs.contains($0.id) }
        return SuggestionResult(suggestions: Array(fresh.prefix(limit)), seedCount: radios.count, seedIDs: seeds.map(\.id))
    }
}
