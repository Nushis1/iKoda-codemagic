import Foundation
import Testing
@testable import KodaCore

@Suite struct DiscoverTasteTests {
    private func song(_ id: String, by artist: String) -> Song {
        Song(id: id, title: id, artistLine: artist)
    }

    @Test func likesRaiseAnArtistAndTwoSkipsStopThem() {
        var taste = DiscoverTaste()
        taste.record(.like, song: song("a", by: "X"))
        #expect(taste.score(of: song("b", by: "X")) == 2)
        taste.record(.skip, song: song("c", by: "Y"))
        #expect(!taste.avoids(song("d", by: "Y")))
        taste.record(.skip, song: song("e", by: "Y"))
        #expect(taste.avoids(song("f", by: "Y")))
        // A like lifts them out of it again.
        taste.record(.like, song: song("g", by: "Y"))
        #expect(!taste.avoids(song("h", by: "Y")))
    }

    @Test func onlyLikesBecomeSeedsAndEveryAnswerIsRemembered() {
        var taste = DiscoverTaste()
        taste.record(.like, song: song("a", by: "X"))
        taste.record(.later, song: song("b", by: "X"))
        taste.record(.skip, song: song("c", by: "Z"))
        #expect(taste.seeds.map(\.id) == ["a"])
        #expect(taste.decided == ["a", "b", "c"])
        taste.record(.like, song: song("a", by: "X"))
        #expect(taste.seeds.count == 1)
        #expect(taste.decided.count == 3)
    }

    @Test func aFileFromBeforeDiscoverStillDecodes() throws {
        let taste = try JSONDecoder().decode(DiscoverTaste.self, from: Data("{}".utf8))
        #expect(taste.isEmpty)
    }

    @MainActor
    @Test func swipesActOnTheLibrary() {
        let library = Library(directory: nil)
        let liked = song("a", by: "X")
        library.answerDiscover(.like, song: liked)
        #expect(library.isLiked(liked))
        library.answerDiscover(.later, song: song("b", by: "X"))
        library.answerDiscover(.later, song: song("c", by: "Y"))
        let later = library.userPlaylists.filter { $0.name == Library.listenLaterName }
        #expect(later.count == 1)
        #expect(later.first?.songs.map(\.id) == ["b", "c"])
        library.answerDiscover(.skip, song: song("d", by: "Z"))
        #expect(!library.isLiked(song("d", by: "Z")))
        #expect(library.discover.decided == ["a", "b", "c", "d"])
        library.clearDiscover()
        #expect(library.discover.isEmpty)
    }

    @Test @MainActor func lockedLikedSongsAreHiddenFromSearchAndSurviveASnapshot() throws {
        let library = Library(directory: nil)
        library.setLiked(song("a", by: "X"), true)
        #expect(library.openLiked.count == 1)
        library.setLikedLocked(true)
        #expect(library.openLiked.isEmpty)
        #expect(library.search("a").songs.isEmpty)
        // An older file lacks the key and starts unlocked.
        let old = try JSONDecoder().decode(Library.Snapshot.self, from: Data("{}".utf8))
        #expect(!old.likedLocked)
    }
}
