import Testing
@testable import KodaCore

@Suite struct DuplicateFinderTests {
    private func song(_ id: String, _ title: String, _ artist: String = "Alpha") -> Song {
        Song(id: id, title: title, artistLine: artist)
    }

    @Test func caseAndAccentsDoNotMakeADifferentSong() {
        let groups = DuplicateFinder.groups(in: [song("a", "SONG"), song("b", "song")])
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .same)
        let accents = DuplicateFinder.groups(in: [song("a", "Café"), song("b", "cafe")])
        #expect(accents.first?.kind == .same)
    }

    @Test func aVersionMarkMakesThemSimilarNotTheSame() {
        for other in ["Song (Remix)", "Song - Live", "Song (Acoustic)"] {
            let groups = DuplicateFinder.groups(in: [song("a", "Song"), song("b", other)])
            #expect(groups.count == 1, "\(other)")
            #expect(groups.first?.kind == .similar, "\(other)")
        }
    }

    @Test func notesAboutGuestsAndRemastersAreSetAside() {
        let groups = DuplicateFinder.groups(in: [
            song("a", "Song"),
            song("b", "Song (feat. Someone)"),
            song("c", "Song (Remastered 2011)"),
        ])
        #expect(groups.count == 1)
        #expect(groups.first?.songs.count == 3)
        #expect(groups.first?.kind == .same)
    }

    @Test func theSameTitleByAnotherArtistIsOnlyAPossibleDuplicate() {
        let groups = DuplicateFinder.groups(in: [song("a", "Intro", "Alpha"), song("b", "Intro", "Beta")])
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .possible)
    }

    @Test func aNameInsideALongerOneIsAPossibleDuplicateWhoeverTheArtist() {
        let groups = DuplicateFinder.groups(in: [
            song("a", "Nowe Ciocie", "Xzy"),
            song("b", "Nowe Ciocie x Looping the Rooms", "Piz"),
            song("c", "Something Else", "Xzy"),
        ])
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .possible)
        #expect(groups.first?.songs.map(\.id) == ["a", "b"])
    }

    @Test func aSingleWordInsideAnotherNameIsNotEnough() {
        #expect(DuplicateFinder.groups(in: [song("a", "Love", "Alpha"), song("b", "Love Story", "Beta")]).isEmpty)
    }

    @Test func everyCopyEndsUpInOneGroup() {
        let groups = DuplicateFinder.groups(in: [
            song("a", "Song", "Alpha"),
            song("b", "SONG", "Alpha"),
            song("c", "song (Remix)", "Alpha"),
            song("d", "Song - Live", "Alpha"),
            song("e", "Song", "Beta"),
            song("f", "Unrelated", "Alpha"),
        ])
        #expect(groups.count == 1)
        #expect(groups.first?.songs.map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @Test func groupsKeepTheListsOrderAndLeaveSinglesOut() {
        let groups = DuplicateFinder.groups(in: [
            song("a1", "Song"),
            song("x", "Other Thing"),
            song("a2", "SONG (Remix)"),
            song("y", "Another"),
            song("y2", "another"),
        ])
        #expect(groups.map { $0.songs.map(\.id) } == [["a1", "a2"], ["y", "y2"]])
    }

    @Test func aListWithoutDuplicatesHasNoGroups() {
        #expect(DuplicateFinder.groups(in: []).isEmpty)
        #expect(DuplicateFinder.groups(in: [song("a", "One"), song("b", "Two")]).isEmpty)
    }
}
