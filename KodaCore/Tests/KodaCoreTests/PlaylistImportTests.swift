import Foundation
import Testing
@testable import KodaCore

@Suite struct PlaylistImportTests {
    // MARK: Links

    @Test func spotifyLinksGiveThePlaylistID() {
        let id = "37i9dQZF1DXcBWIGoYBM5M"
        for text in [
            "https://open.spotify.com/playlist/\(id)?si=abc123",
            "https://open.spotify.com/intl-pl/playlist/\(id)",
            "Listen to this https://open.spotify.com/playlist/\(id) now",
            "open.spotify.com/playlist/\(id)",
            "spotify:playlist:\(id)",
        ] {
            #expect(PlaylistLink.parse(text, as: .spotify)?.id == id, "\(text)")
        }
    }

    @Test func spotifyLinksThatAreNotPlaylistsAreRefused() {
        #expect(PlaylistLink.parse("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", as: .spotify) == nil)
        #expect(PlaylistLink.parse("https://example.com/playlist/37i9dQZF1DXcBWIGoYBM5M", as: .spotify) == nil)
        #expect(PlaylistLink.parse("hello", as: .spotify) == nil)
        #expect(PlaylistLink.parse("https://soundcloud.com/a/sets/b", as: .spotify) == nil)
    }

    @Test func soundCloudLinksLoseTheirTrackingAndShortLinksAreKept() {
        let link = PlaylistLink.parse("https://m.soundcloud.com/some-user/sets/my-mix?utm_source=clipboard&si=1", as: .soundCloud)
        #expect(link?.id == "https://soundcloud.com/some-user/sets/my-mix")
        #expect(link?.isShort == false)
        let short = PlaylistLink.parse("https://on.soundcloud.com/AbCdEf", as: .soundCloud)
        #expect(short?.isShort == true)
        #expect(PlaylistLink.parse("https://soundcloud.com/some-user/tracks", as: .soundCloud) == nil)
        #expect(PlaylistLink.parse("https://soundcloud.com/some-user/some-song", as: .soundCloud) == nil)
    }

    // MARK: Spotify's page

    @Test func theSpotifyEmbedPageGivesTheNameAndTheSongs() throws {
        let html = """
        <html><body><script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"state":{"data":{"entity":{"name":"Road Trip","trackList":[
          {"title":"Blinding Lights","subtitle":"The Weeknd","duration":200040},
          {"title":"Levitating","subtitle":"Dua Lipa,\u{00A0}DaBaby","duration":203064},
          {"title":"","subtitle":"Nobody"}
        ]}}}}}}
        </script></body></html>
        """
        let playlist = try #require(SpotifyEmbed.parse(html: html))
        #expect(playlist.name == "Road Trip")
        #expect(playlist.tracks.map(\.title) == ["Blinding Lights", "Levitating"])
        #expect(playlist.tracks[1].artist == "Dua Lipa, DaBaby")
        #expect(playlist.tracks[0].duration == 200.04)
        #expect(playlist.isPartial == false)
    }

    @Test func aPageWithoutTheListIsNotMistakenForAnEmptyPlaylist() {
        #expect(SpotifyEmbed.parse(html: "<html>no data here</html>") == nil)
        #expect(SpotifyEmbed.parse(html: "<script id=\"__NEXT_DATA__\">{\"a\":1}</script>") == nil)
    }

    // MARK: SoundCloud's data

    @Test func soundCloudTitlesAreSplitIntoArtistAndSong() throws {
        let whole: [String: Any] = ["id": 1, "title": "Daft Punk - One More Time", "duration": 320000, "user": ["username": "uploader"]]
        let track = try #require(SoundCloudJSON.track(whole))
        #expect(track.artist == "Daft Punk")
        #expect(track.title == "One More Time")

        let plain: [String: Any] = ["id": 2, "title": "Tadow", "user": ["username": "Masego"]]
        #expect(SoundCloudJSON.track(plain) == ImportedTrack(title: "Tadow", artist: "Masego"))

        let named: [String: Any] = ["id": 3, "title": "Song - Live", "user": ["username": "label"], "publisher_metadata": ["artist": "Real Artist"]]
        #expect(SoundCloudJSON.track(named)?.artist == "Real Artist")
    }

    @Test func aSoundCloudPlaylistKeepsItsOrderAndSeparatesBareIDs() throws {
        let json = """
        {"kind":"playlist","title":"My Mix","tracks":[
          {"id":10,"title":"A - One","user":{"username":"u"}},
          {"id":11},
          {"id":12,"title":"Three","user":{"username":"v"}}
        ]}
        """
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let playlist = try #require(SoundCloudJSON.playlist(root))
        #expect(playlist.name == "My Mix")
        #expect(playlist.entries.map(\.id) == [10, 11, 12])
        #expect(playlist.entries.map { $0.track == nil } == [false, true, false])
        let notAPlaylist = try JSONSerialization.jsonObject(with: Data("{\"kind\":\"track\"}".utf8))
        #expect(SoundCloudJSON.playlist(notAPlaylist) == nil)
    }

    @Test func theClientIDIsFoundInTheSitesScripts() {
        let page = "<script crossorigin src=\"https://a-v2.sndcdn.com/assets/0-abc.js\"></script><script src=\"https://a-v2.sndcdn.com/assets/1-def.js\"></script>"
        #expect(SoundCloudJSON.scripts(inHTML: page) == ["https://a-v2.sndcdn.com/assets/0-abc.js", "https://a-v2.sndcdn.com/assets/1-def.js"])
        let id = "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6"
        #expect(SoundCloudJSON.clientID(inScript: "var x={api:\"v2\",client_id:\"\(id)\",y:1}") == id)
        #expect(SoundCloudJSON.clientID(inScript: "nothing here") == nil)
    }

    // MARK: Matching

    private func song(_ title: String, _ artist: String, length: TimeInterval? = nil) -> Song {
        Song(id: title + artist, title: title, artistLine: artist, duration: length)
    }

    @Test func theSameSongIsFoundWhateverTheNotesSay() {
        let wanted = ImportedTrack(title: "Blinding Lights", artist: "The Weeknd")
        let best = TrackMatcher.best(for: wanted, in: [
            song("Blinding Lights (Live)", "The Weeknd"),
            song("Blinding Lights", "The Weeknd"),
            song("Save Your Tears", "The Weeknd"),
        ])
        #expect(best?.title == "Blinding Lights")

        let remaster = ImportedTrack(title: "Heroes - 2017 Remaster", artist: "David Bowie")
        #expect(TrackMatcher.best(for: remaster, in: [song("Heroes (2017 Remaster)", "David Bowie")]) != nil)

        let featuring = ImportedTrack(title: "Levitating (feat. DaBaby)", artist: "Dua Lipa, DaBaby")
        #expect(TrackMatcher.best(for: featuring, in: [song("Levitating", "Dua Lipa & DaBaby")]) != nil)
    }

    @Test func anotherSongByTheSameArtistIsNotAMatch() {
        let wanted = ImportedTrack(title: "Blinding Lights", artist: "The Weeknd")
        #expect(TrackMatcher.best(for: wanted, in: [song("Save Your Tears", "The Weeknd"), song("Starboy", "The Weeknd")]) == nil)
        #expect(TrackMatcher.best(for: wanted, in: []) == nil)
    }

    @Test func accentsAndCaseDoNotGetInTheWay() {
        let wanted = ImportedTrack(title: "BEYONCÉ", artist: "Beyoncé")
        #expect(TrackMatcher.best(for: wanted, in: [song("Beyonce", "Beyonce")]) != nil)
    }
}
