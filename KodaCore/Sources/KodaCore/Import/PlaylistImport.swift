import Foundation

/// A song as another service lists it, before it has been found on YouTube Music.
public struct ImportedTrack: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var duration: TimeInterval?

    public init(title: String, artist: String, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

/// A service whose public playlists Koda can bring in from a link.
public enum PlaylistSource: String, Sendable, CaseIterable, Identifiable {
    case spotify, soundCloud

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .spotify: "Spotify"
        case .soundCloud: "SoundCloud"
        }
    }
}

public struct ImportedPlaylist: Sendable, Equatable {
    public var name: String
    public var tracks: [ImportedTrack]
    /// The service showed only the start of a long playlist.
    public var isPartial: Bool

    public init(name: String, tracks: [ImportedTrack], isPartial: Bool = false) {
        self.name = name
        self.tracks = tracks
        self.isPartial = isPartial
    }
}

public enum PlaylistImportError: LocalizedError, Equatable {
    /// Not a link to a playlist of that service.
    case notALink(PlaylistSource)
    /// Private, deleted, or not a playlist at all.
    case unavailable(PlaylistSource)
    /// The service answered, but in a shape Koda doesn't know: its pages change without notice.
    case unreadable(PlaylistSource)
    case empty
    case network

    public var errorDescription: String? {
        switch self {
        case .notALink(let source):
            "That doesn't look like a link to a \(source.name) playlist."
        case .unavailable(let source):
            "Koda couldn't open that \(source.name) playlist. It has to be public, and the link has to be right."
        case .unreadable(let source):
            "\(source.name) answered, but Koda couldn't read the playlist. \(source.name) may have changed its page."
        case .empty:
            "That playlist has no songs in it."
        case .network:
            "Koda couldn't reach the internet."
        }
    }
}

/// A link to a public playlist, tidied up.
public struct PlaylistLink: Sendable, Equatable {
    public var source: PlaylistSource
    /// Spotify: the playlist's id. SoundCloud: its web address.
    public var id: String
    /// SoundCloud's short links (`on.soundcloud.com/…`) go to the playlist and are followed first.
    public var isShort: Bool

    /// Finds the link in what was pasted, which may be a whole "share" message around it.
    public static func parse(_ text: String, as source: PlaylistSource) -> PlaylistLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .spotify:
            if trimmed.lowercased().hasPrefix("spotify:playlist:") {
                let id = String(trimmed.dropFirst("spotify:playlist:".count))
                return isSpotifyID(id) ? PlaylistLink(source: .spotify, id: id, isShort: false) : nil
            }
            guard let url = firstURL(in: trimmed), let host = url.host?.lowercased(),
                  host == "open.spotify.com" || host == "play.spotify.com" else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard let index = parts.firstIndex(of: "playlist"), index + 1 < parts.count,
                  isSpotifyID(parts[index + 1]) else { return nil }
            return PlaylistLink(source: .spotify, id: parts[index + 1], isShort: false)
        case .soundCloud:
            guard let url = firstURL(in: trimmed), let host = url.host?.lowercased(),
                  host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") else { return nil }
            if host == "on.soundcloud.com" {
                return PlaylistLink(source: .soundCloud, id: "https://on.soundcloud.com\(url.path)", isShort: true)
            }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 3, parts.contains("sets") else { return nil }
            // No query: tracking parameters would only get in the way. A private playlist's
            // secret token is part of the path and stays.
            return PlaylistLink(source: .soundCloud, id: "https://soundcloud.com/" + parts.joined(separator: "/"), isShort: false)
        }
    }

    private static func isSpotifyID(_ id: String) -> Bool {
        id.count >= 10 && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func firstURL(in text: String) -> URL? {
        if let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression) {
            return URL(string: String(text[range]))
        }
        // "open.spotify.com/playlist/…" typed or pasted without the scheme.
        return URL(string: "https://" + text)
    }
}

// MARK: - Reading the pages

/// Spotify's public embed page for a playlist: the same page websites put in an iframe. It names
/// the playlist and lists its songs (the first hundred or so) with no sign-in and no API key.
public enum SpotifyEmbed {
    public static func parse(html: String) -> ImportedPlaylist? {
        guard let marker = html.range(of: "id=\"__NEXT_DATA__\""),
              let open = html.range(of: ">", range: marker.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)),
              let container = find("trackList", in: root),
              let list = container["trackList"] as? [Any] else { return nil }
        var tracks: [ImportedTrack] = []
        for case let item as [String: Any] in list {
            guard let title = clean(item["title"] as? String), !title.isEmpty else { continue }
            let milliseconds = (item["duration"] as? NSNumber)?.doubleValue
            tracks.append(ImportedTrack(title: title, artist: clean(item["subtitle"] as? String) ?? "",
                                        duration: milliseconds.map { $0 / 1000 }))
        }
        let name = clean(container["name"] as? String) ?? clean(container["title"] as? String) ?? ""
        return ImportedPlaylist(name: name.isEmpty ? "Spotify Playlist" : name, tracks: tracks, isPartial: tracks.count >= 100)
    }

    /// The dictionary that holds `key`, wherever it sits: the page's layout moves, the name does not.
    private static func find(_ key: String, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] is [Any] { return dictionary }
            for child in dictionary.values {
                if let hit = find(key, in: child) { return hit }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let hit = find(key, in: child) { return hit }
            }
        }
        return nil
    }

    private static func clean(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// SoundCloud's own web API, as its site uses it. It needs the site's public client id, which is
/// read from the site's scripts, so this is the fragile one of the two.
public enum SoundCloudJSON {
    /// One entry of a playlist: the track if SoundCloud sent it whole, or only its id.
    public struct Entry: Sendable, Equatable {
        public var id: Int
        public var track: ImportedTrack?
    }

    public static func playlist(_ root: Any) -> (name: String, entries: [Entry])? {
        guard let dictionary = root as? [String: Any],
              (dictionary["kind"] as? String)?.hasSuffix("playlist") == true,
              let tracks = dictionary["tracks"] as? [Any] else { return nil }
        var entries: [Entry] = []
        for case let item as [String: Any] in tracks {
            guard let id = (item["id"] as? NSNumber)?.intValue else { continue }
            entries.append(Entry(id: id, track: track(item)))
        }
        let name = (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (name.isEmpty ? "SoundCloud Playlist" : name, entries)
    }

    /// A track SoundCloud sent whole. Uploads are often titled "Artist - Song": that is split, unless
    /// the uploader named the artist.
    public static func track(_ item: [String: Any]) -> ImportedTrack? {
        guard let raw = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let user = (item["user"] as? [String: Any])?["username"] as? String
        let metadata = (item["publisher_metadata"] as? [String: Any])
        let artist = (metadata?["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let milliseconds = (item["duration"] as? NSNumber)?.doubleValue
        let duration = milliseconds.map { $0 / 1000 }
        if let artist, !artist.isEmpty {
            let title = (metadata?["release_title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? raw
            return ImportedTrack(title: title, artist: artist, duration: duration)
        }
        if let split = raw.range(of: " - ") {
            let before = raw[..<split.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = raw[split.upperBound...].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty, !after.isEmpty { return ImportedTrack(title: after, artist: before, duration: duration) }
        }
        return ImportedTrack(title: raw, artist: user ?? "", duration: duration)
    }

    /// The addresses of the site's scripts, in the page's order.
    public static func scripts(inHTML html: String) -> [String] {
        matches(#"src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#, in: html)
    }

    /// The client id inside one of those scripts.
    public static func clientID(inScript script: String) -> String? {
        matches(#"client_id\s*[:=]\s*"([A-Za-z0-9]{32})""#, in: script).first
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text).map { String(text[$0]) } : nil
        }
    }
}

// MARK: - Fetching

/// Reads a public playlist from its link.
public struct PlaylistFetcher: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private static let phoneAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public func fetch(_ link: PlaylistLink) async throws -> ImportedPlaylist {
        switch link.source {
        case .spotify: try await spotify(link.id)
        case .soundCloud: try await soundCloud(link)
        }
    }

    private func get(_ url: URL, agent: String, method: String = "GET", source: PlaylistSource) async throws -> (Data, URL) {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PlaylistImportError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw status >= 400 && status < 500 ? PlaylistImportError.unavailable(source) : PlaylistImportError.network
        }
        return (data, response.url ?? url)
    }

    // MARK: Spotify

    private func spotify(_ id: String) async throws -> ImportedPlaylist {
        guard let url = URL(string: "https://open.spotify.com/embed/playlist/\(id)") else { throw PlaylistImportError.notALink(.spotify) }
        let (data, _) = try await get(url, agent: Self.phoneAgent, source: .spotify)
        guard let playlist = SpotifyEmbed.parse(html: String(decoding: data, as: UTF8.self)) else {
            throw PlaylistImportError.unreadable(.spotify)
        }
        guard !playlist.tracks.isEmpty else { throw PlaylistImportError.empty }
        return playlist
    }

    // MARK: SoundCloud

    private func soundCloud(_ link: PlaylistLink) async throws -> ImportedPlaylist {
        guard var address = URL(string: link.id) else { throw PlaylistImportError.notALink(.soundCloud) }
        if link.isShort {
            // A short link redirects to the playlist; only the address it ends at is wanted.
            let (_, final) = try await get(address, agent: Self.desktopAgent, method: "HEAD", source: .soundCloud)
            guard let parsed = PlaylistLink.parse(final.absoluteString, as: .soundCloud), !parsed.isShort,
                  let resolved = URL(string: parsed.id) else { throw PlaylistImportError.unavailable(.soundCloud) }
            address = resolved
        }
        let clientID = try await clientID()
        let root = try await json("https://api-v2.soundcloud.com/resolve", ["url": address.absoluteString, "client_id": clientID])
        guard let found = SoundCloudJSON.playlist(root) else { throw PlaylistImportError.unavailable(.soundCloud) }
        // Only the first few tracks of a playlist come whole; the rest are bare ids, asked for in batches.
        var whole: [Int: ImportedTrack] = [:]
        for entry in found.entries { if let track = entry.track { whole[entry.id] = track } }
        let missing = found.entries.filter { $0.track == nil }.map(\.id)
        for start in stride(from: 0, to: missing.count, by: 30) {
            try Task.checkCancellation()
            let batch = missing[start..<min(start + 30, missing.count)]
            let reply = try await json("https://api-v2.soundcloud.com/tracks",
                                       ["ids": batch.map(String.init).joined(separator: ","), "client_id": clientID])
            for case let item as [String: Any] in (reply as? [Any]) ?? [] {
                if let id = (item["id"] as? NSNumber)?.intValue, let track = SoundCloudJSON.track(item) { whole[id] = track }
            }
        }
        let tracks = found.entries.compactMap { whole[$0.id] }
        guard !tracks.isEmpty else { throw PlaylistImportError.empty }
        return ImportedPlaylist(name: found.name, tracks: tracks)
    }

    private func json(_ base: String, _ query: [String: String]) async throws -> Any {
        guard var components = URLComponents(string: base) else { throw PlaylistImportError.unreadable(.soundCloud) }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw PlaylistImportError.unreadable(.soundCloud) }
        let (data, _) = try await get(url, agent: Self.desktopAgent, source: .soundCloud)
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw PlaylistImportError.unreadable(.soundCloud) }
        return value
    }

    /// SoundCloud's public client id, found in the scripts its home page loads (the newest are last).
    private func clientID() async throws -> String {
        guard let home = URL(string: "https://soundcloud.com/") else { throw PlaylistImportError.unreadable(.soundCloud) }
        let (page, _) = try await get(home, agent: Self.desktopAgent, source: .soundCloud)
        let scripts = SoundCloudJSON.scripts(inHTML: String(decoding: page, as: UTF8.self))
        for script in scripts.reversed() {
            try Task.checkCancellation()
            guard let url = URL(string: script), let reply = try? await get(url, agent: Self.desktopAgent, source: .soundCloud) else { continue }
            if let id = SoundCloudJSON.clientID(inScript: String(decoding: reply.0, as: UTF8.self)) { return id }
        }
        throw PlaylistImportError.unreadable(.soundCloud)
    }
}

// MARK: - Matching

/// Picks the YouTube Music song that is the imported one, or none when nothing is close.
public enum TrackMatcher {
    /// Bracketed notes that say nothing about which song it is.
    private static let notes = ["feat", "ft.", "ft ", "featuring", "with ", "remaster", "version", "mono", "stereo", "deluxe", "bonus", "explicit", "official", "from "]
    /// What makes a different recording of the same song: unwanted unless the imported one has it too.
    private static let versions: Set<String> = ["live", "remix", "cover", "karaoke", "instrumental", "acoustic", "slowed", "sped", "nightcore", "reverb", "8d"]
    private static let filler: Set<String> = ["feat", "ft", "featuring"]

    public static func tokens(_ text: String) -> [String] {
        var result = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if let regex = try? NSRegularExpression(pattern: #"[\(\[][^\)\]]*[\)\]]"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let inner = result[range]
                if notes.contains(where: { inner.contains($0) }) { result.replaceSubrange(range, with: " ") }
            }
        }
        result = result.replacingOccurrences(of: #" - [^-]*(remaster|version|mono|stereo)[^-]*$"#, with: " ", options: .regularExpression)
        return result.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !filler.contains($0) }
    }

    /// 0 for nothing alike, up to about 1.1 for the same song.
    public static func score(_ track: ImportedTrack, _ song: Song) -> Double {
        // Title and artist apart, so a note trimmed from one (" - 2017 Remaster") can't take the other with it.
        let wanted = Set(tokens(track.title)).union(tokens(track.artist))
        let offered = Set(tokens(song.title)).union(tokens(song.artistLine))
        let title = Set(tokens(track.title))
        guard !wanted.isEmpty, !offered.isEmpty, !title.isEmpty else { return 0 }
        let shared = Double(wanted.intersection(offered).count)
        let precision = shared / Double(offered.count)
        let recall = shared / Double(wanted.count)
        guard precision + recall > 0 else { return 0 }
        var score = 2 * precision * recall / (precision + recall)
        // The song's own name has to be there, whatever the artist line says.
        let titleRecall = Double(title.intersection(Set(tokens(song.title))).count) / Double(title.count)
        if titleRecall < 0.5 { return 0 }
        if !versions.intersection(offered).subtracting(wanted).isEmpty { score -= 0.25 }
        if let wantedLength = track.duration, let length = song.duration {
            let difference = abs(wantedLength - length)
            if difference <= 4 { score += 0.1 } else if difference > 20 { score -= 0.15 }
        }
        return score
    }

    public static let threshold = 0.5

    public static func best(for track: ImportedTrack, in songs: [Song]) -> Song? {
        var best: (song: Song, score: Double)?
        for song in songs {
            let value = score(track, song)
            if value > (best?.score ?? 0) { best = (song, value) }
        }
        guard let best, best.score >= threshold else { return nil }
        return best.song
    }
}

// MARK: - Importing

public struct PlaylistImportResult: Sendable {
    public var name: String
    public var songs: [Song]
    /// What could not be found on YouTube Music.
    public var missing: [ImportedTrack]
    public var total: Int
    public var isPartial: Bool
}

/// Reads a public playlist from its link and finds each of its songs on YouTube Music.
public struct PlaylistImporter: Sendable {
    let fetcher: PlaylistFetcher
    let music: YouTubeMusic

    public init(music: YouTubeMusic, session: URLSession = .shared) {
        self.music = music
        self.fetcher = PlaylistFetcher(session: session)
    }

    /// - Parameter progress: told how many songs are matched so far, and how many there are.
    public func run(_ link: PlaylistLink, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> PlaylistImportResult {
        let playlist = try await fetcher.fetch(link)
        let tracks = playlist.tracks
        progress(0, tracks.count)
        var found = [Song?](repeating: nil, count: tracks.count)
        var done = 0
        let music = self.music
        // A few searches at a time: quick enough, and gentle on YouTube.
        await withTaskGroup(of: (Int, Song?).self) { group in
            var next = 0
            while next < min(4, tracks.count) {
                let index = next
                next += 1
                group.addTask { (index, await Self.match(tracks[index], music: music)) }
            }
            while let (index, song) = await group.next() {
                found[index] = song
                done += 1
                progress(done, tracks.count)
                if Task.isCancelled { group.cancelAll(); continue }
                if next < tracks.count {
                    let following = next
                    next += 1
                    group.addTask { (following, await Self.match(tracks[following], music: music)) }
                }
            }
        }
        try Task.checkCancellation()
        var songs: [Song] = []
        var missing: [ImportedTrack] = []
        var seen = Set<String>()
        for (index, track) in tracks.enumerated() {
            if let song = found[index] {
                if seen.insert(song.id).inserted { songs.append(song) }
            } else {
                missing.append(track)
            }
        }
        return PlaylistImportResult(name: playlist.name, songs: songs, missing: missing, total: tracks.count, isPartial: playlist.isPartial)
    }

    private static func match(_ track: ImportedTrack, music: YouTubeMusic) async -> Song? {
        let query = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespaces)
        for _ in 0..<2 {
            do {
                let results = try await music.search(query, filter: .songs)
                var candidates: [Song] = []
                var seen = Set<String>()
                for song in results.topSongs + results.songs where seen.insert(song.id).inserted { candidates.append(song) }
                return TrackMatcher.best(for: track, in: Array(candidates.prefix(8)))
            } catch let error as MusicError where error == .rateLimited {
                try? await Task.sleep(for: .seconds(2))
            } catch {
                return nil
            }
        }
        return nil
    }
}
