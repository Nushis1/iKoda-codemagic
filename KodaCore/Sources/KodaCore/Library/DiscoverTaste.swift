import Foundation

/// What Discover has learned from the listener's swipes: which artists they want more of or less of,
/// which songs they already answered, and the songs they loved, which the next songs are found from.
public struct DiscoverTaste: Codable, Sendable, Equatable {
    public enum Answer: String, Codable, Sendable {
        /// Swiped right: liked, and more like it.
        case like
        /// Swiped left: not this one, and a little less of the artist.
        case skip
        /// Swiped down: kept for later, and a little more of the artist.
        case later
    }

    /// Lead artist's name → how much the listener wants them: up for likes and saves, down for skips.
    public private(set) var artistScores: [String: Double] = [:]
    /// Songs already answered, oldest first: Discover never shows one twice.
    public private(set) var decided: [String] = []
    /// Songs liked in Discover, newest first: the next songs are found from their radios.
    public private(set) var seeds: [Song] = []

    static let maxDecided = 2_000
    static let maxSeeds = 30
    static let maxArtists = 400
    static let scoreRange = -6.0...10.0
    /// An artist skipped this far down is no longer offered.
    public static let avoidBelow = -2.0

    public init() {}

    public var isEmpty: Bool { artistScores.isEmpty && decided.isEmpty && seeds.isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artistScores = try c.decodeIfPresent([String: Double].self, forKey: .artistScores) ?? [:]
        decided = try c.decodeIfPresent([String].self, forKey: .decided) ?? []
        seeds = try c.decodeIfPresent([Song].self, forKey: .seeds) ?? []
    }

    public func score(of song: Song) -> Double { artistScores[Taste.leadArtist(song)] ?? 0 }

    /// The listener has skipped this artist enough that Discover stops offering them.
    public func avoids(_ song: Song) -> Bool { score(of: song) <= Self.avoidBelow }

    public mutating func record(_ answer: Answer, song: Song) {
        let artist = Taste.leadArtist(song)
        let change: Double
        switch answer {
        case .like: change = 2
        case .later: change = 1
        case .skip: change = -1
        }
        if !artist.isEmpty {
            let score = (artistScores[artist] ?? 0) + change
            artistScores[artist] = min(Self.scoreRange.upperBound, max(Self.scoreRange.lowerBound, score))
        }
        if answer == .like {
            seeds.removeAll { $0.id == song.id }
            seeds.insert(song, at: 0)
            if seeds.count > Self.maxSeeds { seeds.removeLast(seeds.count - Self.maxSeeds) }
        }
        if !decided.contains(song.id) { decided.append(song.id) }
        if decided.count > Self.maxDecided { decided.removeFirst(decided.count - Self.maxDecided) }
        if artistScores.count > Self.maxArtists {
            // The ones nearest zero say the least.
            let weakest = artistScores.sorted { abs($0.value) < abs($1.value) }.prefix(artistScores.count - Self.maxArtists)
            for (name, _) in weakest { artistScores[name] = nil }
        }
    }
}
