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

/// The microphone's audio on its way to a file. Used by the audio thread until the tap is removed, then closed.
nonisolated private final class Recording: @unchecked Sendable {
    var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init(to url: URL, from input: AVAudioFormat) throws {
        // Mono, 44.1 kHz, 16 bit: a clear recording that is about 1 MB for twelve seconds.
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        guard let converter = AVAudioConverter(from: input, to: file.processingFormat) else { throw RecognitionError.failed }
        self.file = file
        self.converter = converter
        format = file.processingFormat
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
        if failure == nil, converted.frameLength > 0 { try? file?.write(from: converted) }
    }
}

/// Listens through the microphone for `seconds` and returns the recording as a WAV file.
/// Run here, off the main actor, so no audio type crosses it.
nonisolated private func record(seconds: Int) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "koda-recognition-\(UUID().uuidString).wav")
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let recording = try Recording(to: url, from: format)
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        recording.append(buffer)
    }
    let session = AVAudioSession.sharedInstance()
    // Hands the audio back to playback as Koda had it, however this ends.
    defer {
        if engine.isRunning { engine.stop() }
        input.removeTap(onBus: 0)
        recording.file = nil
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    try session.setCategory(.record, mode: .measurement, options: .duckOthers)
    try session.setActive(true, options: .notifyOthersOnDeactivation)
    engine.prepare()
    try engine.start()
    try await Task.sleep(for: .seconds(seconds))
    return url
}

/// Asks AudD (api.audd.io, a music recognition service with an official API) what the recording is;
/// nil when it knows no such song.
nonisolated private func identify(_ recording: URL, token: String) async throws -> HeardSong? {
    let boundary = "koda-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    field("api_token", token)
    field("return", "apple_music")
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(try Data(contentsOf: recording))
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
        case needsToken
        case badToken
    }

    private(set) var phase = Phase.listening

    /// Long enough for a chorus, and about what AudD analyzes.
    private static let seconds = 12

    func start(music: YouTubeMusic, token: String) async {
        phase = .listening
        guard !token.isEmpty else {
            phase = .needsToken
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .blocked
            return
        }
        var heard: HeardSong?
        do {
            let file = try await record(seconds: Self.seconds)
            defer { try? FileManager.default.removeItem(at: file) }
            heard = try await identify(file, token: token)
        } catch RecognitionError.token {
            phase = .badToken
            return
        } catch {
            heard = nil
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
            case .needsToken:
                message("Add your AudD token", detail: "Music Recognition uses AudD, which gives you 300 free recognitions. Get a token, then paste it in Settings → Music Recognition.", action: .audd)
            case .badToken:
                message("AudD didn't accept the token", detail: "Check it in Settings → Music Recognition. The free recognitions may be used up.", action: .audd)
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
                Button("Get a Token") {
                    if let url = URL(string: "https://dashboard.audd.io") { openURL(url) }
                }
                .buttonStyle(.glass)
            }
        }
    }
}

/// Settings → Music Recognition: the listener's own AudD token.
struct RecognitionSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                SecureField("AudD API token", text: $settings.recognitionToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Music Recognition sends 12 seconds of what the microphone hears to AudD, a recognition service, and nothing else. A free account gives 300 recognitions; after that AudD charges for more. Get a token at dashboard.audd.io.")
            }
            Section {
                Link("Open dashboard.audd.io", destination: URL(string: "https://dashboard.audd.io")!)
            }
        }
        .navigationTitle("Music Recognition")
    }
}
