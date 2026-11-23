import AVFoundation
import KodaCore
import SwiftUI

/// What was heard.
nonisolated struct HeardSong: Equatable, Sendable {
    var title: String
    var artist: String
    var artworkURL: URL?
}

nonisolated private enum RecognitionError: Error {
    /// AudD refused the token (wrong, or its free recognitions are used up).
    case token
    case failed
}

/// The microphone's audio on its way to memory, as mono 16 kHz. Used by the audio thread until the tap is removed.
nonisolated private final class Recording: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Float] = []
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init(from input: AVAudioFormat) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SoundSignature.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: format) else { throw RecognitionError.failed }
        self.format = format
        self.converter = converter
    }

    var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var handedOver = false
        var failure: NSError?
        converter.convert(to: converted, error: &failure) { _, status in
            if handedOver {
                status.pointee = .noDataNow
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        lock.lock()
        collected += chunk
        lock.unlock()
    }
}

/// Listens through the microphone for `seconds`; the audio as mono 16 kHz, samples from -1 to 1.
nonisolated private func record(seconds: Int) async throws -> [Float] {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let recording = try Recording(from: format)
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        recording.append(buffer)
    }
    let session = AVAudioSession.sharedInstance()
    // Hands the audio back to playback as Koda had it, however this ends.
    defer {
        if engine.isRunning { engine.stop() }
        input.removeTap(onBus: 0)
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    try session.setCategory(.record, mode: .measurement, options: .duckOthers)
    try session.setActive(true, options: .notifyOthersOnDeactivation)
    engine.prepare()
    try engine.start()
    try await Task.sleep(for: .seconds(seconds))
    return recording.samples
}

/// Asks Shazam's recognition service what the fingerprint is; nil when it knows no such song.
/// Only the fingerprint is sent, never the recording.
nonisolated private func askShazam(_ signature: SoundSignature) async throws -> HeardSong? {
    let agents = [
        "Dalvik/2.1.0 (Linux; U; Android 6.0.1; SM-G920F Build/MMB29K)",
        "Dalvik/2.1.0 (Linux; U; Android 5.1.1; SM-J500FN Build/LMY48B)",
        "Dalvik/2.1.0 (Linux; U; Android 5.0; SM-G900F Build/LRX21T)",
        "Dalvik/1.6.0 (Linux; U; Android 4.4.4; SM-G360H Build/KTU84P)",
    ]
    let url = "https://amp.shazam.com/discovery/v5/en/US/android/-/tag/\(UUID().uuidString)/\(UUID().uuidString.lowercased())"
        + "?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&sharehub=true&video=v3"
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("en_US", forHTTPHeaderField: "Content-Language")
    request.setValue(agents.randomElement(), forHTTPHeaderField: "User-Agent")
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let body: [String: Any] = [
        "geolocation": ["altitude": 300, "latitude": 45, "longitude": 2],
        "signature": ["samplems": signature.milliseconds, "timestamp": now, "uri": signature.uri],
        "timestamp": now,
        "timezone": TimeZone.current.identifier,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    // Anything but a plain answer (rate limited, refused) is a failure, not "no such song".
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RecognitionError.failed }
    guard let matches = root["matches"] as? [Any], !matches.isEmpty,
          let track = root["track"] as? [String: Any], let title = track["title"] as? String else { return nil }
    let images = track["images"] as? [String: Any]
    let cover = (images?["coverarthq"] as? String) ?? (images?["coverart"] as? String)
    return HeardSong(title: title, artist: track["subtitle"] as? String ?? "", artworkURL: cover.flatMap(URL.init(string:)))
}

/// The recording as a WAV file's bytes: mono, 16 bit.
nonisolated private func wav(_ samples: [Float]) -> Data {
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let rate = UInt32(SoundSignature.sampleRate)
    data.append(contentsOf: Array("RIFF".utf8))
    put(UInt32(36 + samples.count * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    put(UInt32(samples.count * 2))
    for sample in samples { put(Int16(max(-32768, min(32767, (sample * 32768).rounded())))) }
    return data
}

/// The backup: AudD (api.audd.io), a recognition service with an official API and the listener's own token.
/// It is sent the recording; nil when it knows no such song.
nonisolated private func askAudD(_ samples: [Float], token: String) async throws -> HeardSong? {
    let boundary = "koda-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    field("api_token", token)
    field("return", "apple_music")
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(wav(samples))
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var request = URLRequest(url: URL(string: "https://api.audd.io/")!, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let (data, _) = try await URLSession.shared.upload(for: request, from: body)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RecognitionError.failed }
    if root["status"] as? String != "success" {
        // 900: wrong token. 901: no token, or its free requests are used up.
        let code = (root["error"] as? [String: Any])?["error_code"] as? Int
        throw code == 900 || code == 901 ? RecognitionError.token : RecognitionError.failed
    }
    guard let result = root["result"] as? [String: Any], let title = result["title"] as? String else { return nil }
    let artwork = ((result["apple_music"] as? [String: Any])?["artwork"] as? [String: Any])?["url"] as? String
    let cover = artwork?.replacingOccurrences(of: "{w}", with: "400").replacingOccurrences(of: "{h}", with: "400")
    return HeardSong(title: title, artist: result["artist"] as? String ?? "", artworkURL: cover.flatMap(URL.init(string:)))
}

/// Music Recognition: hears a song and finds it on YouTube Music, so it can be played or kept.
@MainActor
@Observable
final class SongRecognition {
    enum Phase {
        case listening
        /// Heard, and found to play.
        case found(HeardSong, Song)
        /// Heard, but nothing to play was found for it.
        case notFound(HeardSong)
        case noMatch
        case blocked
        /// The backup service refused the token, and the first one didn't answer.
        case badToken
    }

    private(set) var phase = Phase.listening

    /// Long enough for a chorus; the length a fingerprint covers.
    private static let seconds = SoundSignature.seconds

    /// Names the song with a fingerprint made here; if that service doesn't answer and the listener
    /// has given an AudD token, the recording goes to AudD instead.
    func start(music: YouTubeMusic, token: String) async {
        phase = .listening
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .blocked
            return
        }
        guard let samples = try? await record(seconds: Self.seconds), !Task.isCancelled else {
            if !Task.isCancelled { phase = .noMatch }
            return
        }
        var heard: HeardSong?
        var answered = true
        do {
            let signature = await Task.detached(priority: .userInitiated) { SoundSignature(samples: samples) }.value
            heard = try await askShazam(signature)
        } catch {
            answered = false
        }
        if !answered, !token.isEmpty {
            do {
                heard = try await askAudD(samples, token: token)
            } catch RecognitionError.token {
                phase = .badToken
                return
            } catch {}
        }
        guard !Task.isCancelled else { return }
        guard let heard else {
            phase = .noMatch
            return
        }
        let query = "\(heard.title) \(heard.artist)".trimmingCharacters(in: .whitespaces)
        let song = try? await music.search(query, filter: .songs).songs.first
        guard !Task.isCancelled else { return }
        phase = song.map { .found(heard, $0) } ?? .notFound(heard)
    }
}

/// The recognition sheet: listening, then the song with what can be done with it.
struct SongRecognitionSheet: View {
    /// Called when a song is played from here, so the music that was paused for listening isn't resumed over it.
    let onPlay: () -> Void
    let onSearch: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recognition = SongRecognition()
    @State private var attempt = 0

    private enum Action {
        case retry
        case settings
        case audd
    }

    var body: some View {
        VStack(spacing: 20) {
            switch recognition.phase {
            case .listening:
                listening
            case .found(let heard, let song):
                result(heard, song: song)
            case .notFound(let heard):
                result(heard, song: nil)
            case .noMatch:
                message("Couldn't find the song", detail: "Hold your iPhone closer to the music and try again.", action: .retry)
            case .blocked:
                message("Koda can't listen", detail: "Allow the microphone for Koda in Settings.", action: .settings)
            case .badToken:
                message("Couldn't find the song", detail: "The main service didn't answer, and AudD didn't accept your backup token. Check it in Settings → Music Recognition.", action: .audd)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(16)
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
        .task(id: attempt) { await recognition.start(music: app.music, token: app.settings.recognitionToken) }
        // Going to an artist or album from the menu closes the sheet.
        .onChange(of: app.pendingRoute != nil) { _, pending in if pending { dismiss() } }
    }

    private var listening: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: .circle)
            Text("Listening…").font(.title3.weight(.semibold))
            Text("Hold your iPhone near the music").foregroundStyle(.secondary)
        }
        .sensoryFeedback(.start, trigger: attempt)
    }

    private func result(_ heard: HeardSong, song: Song?) -> some View {
        VStack(spacing: 18) {
            AsyncImage(url: heard.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 132, height: 132)
            .clipShape(.rect(cornerRadius: 14))
            VStack(spacing: 4) {
                Text(heard.title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(heard.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            .multilineTextAlignment(.center)
            if let song {
                HStack(spacing: 12) {
                    Button {
                        onPlay()
                        player.startRadio(from: song)
                        dismiss()
                    } label: {
                        Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 18)
                    }
                    .buttonStyle(.glass)
                    Menu {
                        SongMenuItems(song: song)
                    } label: {
                        Image(systemName: "ellipsis").font(.headline).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("More")
                }
            } else {
                Text("Couldn't find it to play.").font(.footnote).foregroundStyle(.secondary)
                Button("Search for It") {
                    onSearch("\(heard.title) \(heard.artist)")
                    dismiss()
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func message(_ title: String, detail: String, action: Action) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            switch action {
            case .retry:
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.glass)
            case .settings:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glass)
            case .audd:
                Button("Open AudD") {
                    if let url = URL(string: "https://dashboard.audd.io") { openURL(url) }
                }
                .buttonStyle(.glass)
            }
        }
    }
}

/// Settings → Music Recognition: the listener's own AudD token, which is only a backup.
struct RecognitionSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                SecureField("AudD API token (optional)", text: $settings.recognitionToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Koda recognizes a song by making a fingerprint of 12 seconds of what the microphone hears on this iPhone, and sending only the fingerprint to Shazam's service. No token is needed.\n\nIf that service doesn't answer, Koda can send the recording to AudD instead, with your own token: a free account gives 300 recognitions, then AudD charges.")
            }
            Section {
                Link("Open dashboard.audd.io", destination: URL(string: "https://dashboard.audd.io")!)
            }
        }
        .navigationTitle("Music Recognition")
    }
}
