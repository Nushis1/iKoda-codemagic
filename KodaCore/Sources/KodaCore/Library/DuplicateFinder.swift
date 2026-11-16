import Foundation

/// Songs of one list that look like the same song under different names.
public struct DuplicateGroup: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// The names agree once case, accents and notes like "(feat. X)" or "(Remastered)" are set aside.
        case same
        /// The names agree only once a version mark such as "(Remix)", "- Live" or "(Acoustic)" is set aside.
        case similar
    }

    public let kind: Kind
    /// In the order they have in the list.
    public let songs: [Song]

    public var id: String { songs.map(\.id).joined(separator: "|") }
}

/// Finds songs in a list that are probably the same song: "SONG" and "song", or "Song" and "Song (Remix)".
/// Two songs have to share an artist, or "Intro" by two bands would be one song.
public enum DuplicateFinder {
    /// Words that don't make a different song: how the upload is dressed, not what it is.
    private static let dressing: Set<String> = [
        "official", "video", "audio", "lyrics", "lyric", "visualizer", "visualiser",
        "hd", "hq", "music", "clip", "explicit", "version",
    ]

    struct Keys {
        /// The title's words as they are, notes already dropped.
        var full: String
        /// The title without version marks and dressing.
        var core: String
        var artists: Set<String>
    }

    static func keys(for song: Song) -> Keys {
        let words = TrackMatcher.tokens(song.title)
        let core = words.filter { !TrackMatcher.versions.contains($0) && !dressing.contains($0) }
        return Keys(full: words.joined(separator: " "),
                    core: core.joined(separator: " "),
                    artists: Set(TrackMatcher.tokens(song.artistLine)))
    }

    private static func related(_ a: Keys, _ b: Keys) -> Bool {
        if a.artists.isEmpty && b.artists.isEmpty { return true }
        return !a.artists.isDisjoint(with: b.artists)
    }

    /// The groups of two or more songs, by where their first song stands in the list.
    public static func groups(in songs: [Song]) -> [DuplicateGroup] {
        let keys = songs.map { keys(for: $0) }
        var parent = Array(songs.indices)

        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        // Only songs with the same core title are compared, which keeps a long list quick.
        var buckets: [String: [Int]] = [:]
        for (index, key) in keys.enumerated() where !key.core.isEmpty {
            buckets[key.core, default: []].append(index)
        }
        for indices in buckets.values {
            for (offset, first) in indices.enumerated() {
                for second in indices[(offset + 1)...] where related(keys[first], keys[second]) {
                    let (a, b) = (root(first), root(second))
                    if a != b { parent[max(a, b)] = min(a, b) }
                }
            }
        }

        var members: [Int: [Int]] = [:]
        for index in songs.indices { members[root(index), default: []].append(index) }
        return members.values
            .filter { $0.count > 1 }
            .sorted { $0[0] < $1[0] }
            .map { indices in
                let same = Set(indices.map { keys[$0].full }).count == 1
                return DuplicateGroup(kind: same ? .same : .similar, songs: indices.map { songs[$0] })
            }
    }
}
