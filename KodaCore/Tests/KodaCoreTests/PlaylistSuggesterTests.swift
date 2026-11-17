import Testing
@testable import KodaCore

@Suite struct PlaylistSuggesterTests {
    private func song(_ id: String, _ title: String? = nil, _ artist: String = "Alpha") -> Song {
        Song(id: id, title: title ?? id, artistLine: artist)
    }

    @Test func theSongsMostRadiosAgreeOnComeFirst() {
        let radios = [
            [song("a"), song("b"), song("c")],
            [song("b"), song("c"), song("d")],
            [song("c"), song("x")],
        ]
        let ranked = PlaylistSuggester.rank(radios: radios, playlist: [])
        // c in three radios, b in two; a, x and d once each, the closest first.
        #expect(ranked.map(\.id) == ["c", "b", "a", "x", "d"])
        #expect(ranked.map(\.votes) == [3, 2, 1, 1, 1])
    }

    @Test func aSongCountsOncePerRadioEvenIfItIsListedTwice() {
        let ranked = PlaylistSuggester.rank(radios: [[song("a"), song("a")], [song("b")]], playlist: [])
        #expect(ranked.first(where: { $0.id == "a" })?.votes == 1)
    }

    @Test func whatThePlaylistAlreadyHasIsLeftOutInAnyUpload() {
        let playlist = [song("p1", "Hit Song", "Alpha")]
        let radios = [[
            song("p1", "Hit Song", "Alpha"),
            song("q1", "HIT SONG (Live)", "Alpha"),
            song("q2", "Fresh One", "Beta"),
        ]]
        #expect(PlaylistSuggester.rank(radios: radios, playlist: playlist).map(\.id) == ["q2"])
    }

    @Test func aSecondUploadOfASuggestionIsLeftOut() {
        let radios = [[song("m", "Hit", "Alpha"), song("n", "Hit (Remix)", "Alpha"), song("o", "Other", "Beta")]]
        #expect(PlaylistSuggester.rank(radios: radios, playlist: []).map(\.id) == ["m", "o"])
    }

    @Test func theListStopsAtTheLimit() {
        let radio = (1...20).map { song("s\($0)", "Song \($0)", "Artist \($0)") }
        #expect(PlaylistSuggester.rank(radios: [radio], playlist: [], limit: 5).count == 5)
    }

    @Test func seedsAreFewerOfTheSameSongs() {
        let songs = (1...10).map { song("s\($0)") }
        var generator = SystemRandomNumberGenerator()
        let seeds = PlaylistSuggester.pickSeeds(from: songs, count: 5, using: &generator)
        #expect(seeds.count == 5)
        #expect(Set(seeds.map(\.id)).count == 5)
        #expect(Set(seeds.map(\.id)).isSubset(of: Set(songs.map(\.id))))
        #expect(PlaylistSuggester.pickSeeds(from: Array(songs.prefix(2)), count: 5, using: &generator).count == 2)
    }
}
