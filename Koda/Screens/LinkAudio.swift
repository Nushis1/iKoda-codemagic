import AVFoundation
import KodaCore

nonisolated enum LinkAudioError: Error {
    /// Not a link to a video Koda can take sound from.
    case unsupported
}

/// The sound of a video behind a link, for Music Recognition: a YouTube link (a Short, a video) or a
/// TikTok one. Only the first seconds are read, and nothing is kept.
///
/// YouTube is Koda's own stream lookup. TikTok has no official way in: its page is read for the sound's
/// own file and the video, and for the song's name when it names one. That page is TikTok's to change,
/// so it is a best effort, and a link it won't give up simply isn't recognized.
nonisolated struct LinkAudio: Sendable {
    /// Mono 16 kHz audio; empty when none could be read.
    var samples: [Float]
    /// The song, when the page itself names it.
    var named: HeardSong?

    /// Seconds read: enough that the middle twelve are a chorus, not an intro.
    private static let limit = 40.0
    private static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    static func load(_ url: URL, music: YouTubeMusic) async throws -> LinkAudio {
        let host = url.host?.lowercased() ?? ""
        if let link = YouTubeLink(url) {
            guard case .song(let videoId) = link else { throw LinkAudioError.unsupported }
            return LinkAudio(samples: (try? await youTube(videoId, music: music)) ?? [], named: nil)
        }
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") { return await tikTok(url) }
        throw LinkAudioError.unsupported
    }

    // MARK: YouTube

    private static func youTube(_ videoId: String, music: YouTubeMusic) async throws -> [Float] {
        let stream = try await music.stream(for: videoId)
        // A concert recording isn't a song someone shares to find out its name.
        if let length = stream.contentLength, length > 40_000_000 { return [] }
        var headers = ["User-Agent": stream.userAgent]
        if let length = stream.contentLength, length > 0 { headers["Range"] = "bytes=0-\(length - 1)" }
        let file = try await download(stream.url, headers: headers, as: "m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        // AVFoundation reads YouTube's fragmented M4A as longer than it is, so stop at its real length.
        return try await decode(file, limit: min(stream.duration ?? limit, limit))
    }

    // MARK: TikTok

    private static func tikTok(_ url: URL) async -> LinkAudio {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(desktop, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let page = String(data: data, encoding: .utf8),
              let details = item(inPage: page) else { return LinkAudio(samples: [], named: nil) }
        let sound = details["music"] as? [String: Any]
        let video = details["video"] as? [String: Any]

        var named: HeardSong?
        if let title = sound?["title"] as? String, !title.isEmpty, !isOriginalSound(title) {
            named = HeardSong(title: title, artist: sound?["authorName"] as? String ?? "", artworkURL: nil)
        }
        // The sound's own file first: it is just the music. Then the video's.
        let sources = [sound?["playUrl"], video?["playAddr"], video?["downloadAddr"]]
            .compactMap { $0 as? String }.filter { !$0.isEmpty }.compactMap(URL.init(string:))
        for source in sources {
            let headers = ["User-Agent": desktop, "Referer": "https://www.tiktok.com/"]
            guard let file = try? await download(source, headers: headers, as: "mp4") else { continue }
            defer { try? FileManager.default.removeItem(at: file) }
            if let samples = try? await decode(file, limit: limit), samples.count > 2 * 16_000 {
                return LinkAudio(samples: samples, named: named)
            }
        }
        return LinkAudio(samples: [], named: named)
    }

    /// The video's data in a TikTok page: it is embedded as JSON for the page's own scripts.
    private static func item(inPage page: String) -> [String: Any]? {
        guard let start = page.range(of: "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\""),
              let open = page.range(of: ">", range: start.upperBound..<page.endIndex),
              let close = page.range(of: "</script>", range: open.upperBound..<page.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(page[open.upperBound..<close.lowerBound].utf8)) as? [String: Any],
              let scope = json["__DEFAULT_SCOPE__"] as? [String: Any],
              let detail = scope["webapp.video-detail"] as? [String: Any],
              let info = detail["itemInfo"] as? [String: Any] else { return nil }
        return info["itemStruct"] as? [String: Any]
    }

    /// A creator's own audio has no song to name.
    private static func isOriginalSound(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return ["original sound", "original audio", "dźwięk oryginalny", "oryginalny dźwięk", "оригинальный звук", "sonido original", "son original"]
            .contains { lowered.contains($0) }
    }

    // MARK: Fetching and reading

    private static func download(_ url: URL, headers: [String: String], as fileExtension: String) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 206 else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "koda-link-\(UUID().uuidString).\(fileExtension)")
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// The first `limit` seconds of the file's audio, mono at 16 kHz.
    private static func decode(_ file: URL, limit: TimeInterval) async throws -> [Float] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 1000))
        let rate = Double(SoundSignature.sampleRate)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var mono: [Float] = []
        mono.reserveCapacity(Int(limit * rate) + 1024)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer),
                  let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = max(1, Int(description.mChannelsPerFrame))
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if channels == 1 {
                mono.append(contentsOf: interleaved)
            } else {
                for frame in 0..<interleaved.count / channels {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += interleaved[frame * channels + channel] }
                    mono.append(sum / Float(channels))
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return mono
    }
}
