import Foundation

/// Songs of one list that look like the same song under different names.
public struct DuplicateGroup: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// The names agree once case, accents and notes like "(feat. X)" or "(Remastered)" are set aside.
        case same
        /// The names agree only once a version mark such as "(Remix)", "- Live" or "(Acoustic)" is set aside.
        case similar
        /// Not sure: the same name by different artists, or one name inside a longer one
        /// ("Nowe Ciocie" and "Nowe Ciocie x Looping the Rooms"). It may be another song, or the same.
        case possible
    }

    public let kind: Kind
    /// Every song of the group, in the order they have in the list.
    public let songs: [Song]

    public var id: String { songs.map(\.id).joined(separator: "|") }
}

/// Finds songs in a list that are probably the same song: "SONG" and "song", "Song" and "Song (Remix)",
/// or a name that sits inside a longer one. Everything that is linked, however many songs that is, ends
/// up in one group.
public enum DuplicateFinder {
    /// Words that don't make a different song: how the upload is dressed, not what it is.
    private static let dressing: Set<String> = [
        "official", "video", "audio", "lyrics", "lyric", "visualizer", "visualiser",
        "hd", "hq", "music", "clip", "explicit", "version",
    ]

    /// Words that say little about which song it is. A name inside another counts only by its other words.
    private static let filler: Set<String> = [
        "the", "a", "an", "and", "of", "x", "feat", "ft", "with", "vs", "in", "on", "to", "i", "w", "z", "na", "do",
    ]

    struct Keys {
        /// The title's words as they are, notes already dropped.
        var full: String
        /// The title without version marks and dressing.
        var core: String
        var coreWords: Set<String>
        var artists: Set<String>
    }

    static func keys(for song: Song) -> Keys {
        let words = TrackMatcher.tokens(song.title)
        let core = words.filter { !TrackMatcher.versions.contains($0) && !dressing.contains($0) }
        return Keys(full: words.joined(separator: " "),
                    core: core.joined(separator: " "),
                    coreWords: Set(core),
                    artists: Set(TrackMatcher.tokens(song.artistLine)))
    }

    static func sameArtist(_ a: Keys, _ b: Keys) -> Bool {
        if a.artists.isEmpty && b.artists.isEmpty { return true }
        return !a.artists.isDisjoint(with: b.artists)
    }

    /// The groups of two or more songs, by where their first song stands in the list.
    public static func groups(in songs: [Song]) -> [DuplicateGroup] {
        let keys = songs.map { keys(for: $0) }
        var parent = Array(songs.indices)
        /// Songs that are in the group through a doubtful link.
        var doubtful = Set<Int>()

        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        func join(_ first: Int, _ second: Int, doubtfully: Bool) {
            let (a, b) = (root(first), root(second))
            if a != b { parent[max(a, b)] = min(a, b) }
            if doubtfully {
                doubtful.insert(first)
                doubtful.insert(second)
            }
        }

        // 1. The same title once marks are set aside: sure if an artist is shared, a maybe if not.
        var buckets: [String: [Int]] = [:]
        for (index, key) in keys.enumerated() where !key.core.isEmpty {
            buckets[key.core, default: []].append(index)
        }
        for indices in buckets.values {
            for (offset, first) in indices.enumerated() {
                for second in indices[(offset + 1)...] {
                    join(first, second, doubtfully: !sameArtist(keys[first], keys[second]))
                }
            }
        }

        // 2. A title that sits inside a longer one, whoever the artist is: always a maybe. The shorter
        // one needs two real words, or "Love" would be inside every love song.
        var songsWithWord: [String: [Int]] = [:]
        for (index, key) in keys.enumerated() {
            for word in key.coreWords { songsWithWord[word, default: []].append(index) }
        }
        for (index, key) in keys.enumerated() {
            let meaningful = key.coreWords.subtracting(filler)
            guard meaningful.count >= 2 else { continue }
            let lists = key.coreWords.compactMap { songsWithWord[$0] }
            guard lists.count == key.coreWords.count, let shortest = lists.min(by: { $0.count < $1.count }) else { continue }
            for other in shortest where other != index
                && keys[other].coreWords.count > key.coreWords.count
                && key.coreWords.isSubset(of: keys[other].coreWords) {
                join(index, other, doubtfully: true)
            }
        }

        var members: [Int: [Int]] = [:]
        for index in songs.indices { members[root(index), default: []].append(index) }
        return members.values
            .filter { $0.count > 1 }
            .sorted { $0[0] < $1[0] }
            .map { indices in
                let kind: DuplicateGroup.Kind
                if indices.contains(where: { doubtful.contains($0) }) {
                    kind = .possible
                } else if Set(indices.map { keys[$0].full }).count == 1 {
                    kind = .same
                } else {
                    kind = .similar
                }
                return DuplicateGroup(kind: kind, songs: indices.map { songs[$0] })
            }
    }
}
