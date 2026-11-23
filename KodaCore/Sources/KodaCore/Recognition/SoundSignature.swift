import Foundation

/// A fingerprint of twelve seconds of music, made on the phone: the loudest points of its spectrogram,
/// grouped by pitch range. It is written in the layout Shazam's recognition service reads, so the
/// service can name the song without Koda ever sending the recording itself.
///
/// The method is the well-known one (Wang, "An Industrial-Strength Audio Search Algorithm"): 2048-sample
/// windows every 128 samples of 16 kHz audio, and a point counts as a peak when it is louder than its
/// neighbours in pitch and in time. The constants are the ones the service expects.
public struct SoundSignature: Sendable, Equatable {
    public struct Peak: Sendable, Equatable {
        /// Which window, counted from the start of the recording.
        public var pass: UInt32
        public var magnitude: UInt16
        /// The peak's frequency in 1/64ths of a bin of the 2048-point transform.
        public var bin: UInt16
    }

    public static let sampleRate = 16_000
    /// Seconds of audio a signature covers.
    public static let seconds = 12

    public private(set) var sampleCount: Int
    /// Peaks of 250–520 Hz, 520–1450 Hz, 1450–3500 Hz and 3500–5500 Hz.
    public private(set) var bands: [[Peak]]

    public init(sampleCount: Int, bands: [[Peak]]) {
        self.sampleCount = sampleCount
        self.bands = bands
    }

    /// The signature of mono 16 kHz audio, samples from -1 to 1. A recording longer than twelve seconds
    /// is taken from its middle, a shorter one is padded with silence.
    public init(samples: [Float]) {
        let wanted = Self.seconds * Self.sampleRate
        var audio = samples
        if audio.count < wanted { audio += [Float](repeating: 0, count: wanted - audio.count) }
        if audio.count > wanted {
            let start = audio.count / 2 - wanted / 2
            audio = Array(audio[start..<start + wanted])
        }
        var analyzer = Analyzer()
        for start in stride(from: 0, through: audio.count - Analyzer.hop, by: Analyzer.hop) {
            analyzer.add(audio[start..<start + Analyzer.hop])
        }
        self.init(sampleCount: audio.count, bands: analyzer.bands)
    }

    public var milliseconds: Int { sampleCount * 1000 / Self.sampleRate }

    public var peakCount: Int { bands.reduce(0) { $0 + $1.count } }

    // MARK: Binary form

    static let prefix = "data:audio/vnd.shazam.sig;base64,"

    /// The signature as the service reads it: a 48-byte header, then one block of peaks per band.
    public var data: Data {
        var body = Data()
        for (band, peaks) in bands.enumerated() where !peaks.isEmpty {
            var block = Data()
            var pass: UInt32 = 0
            for peak in peaks {
                // A gap of 255 windows or more doesn't fit the byte, so the pass number is given whole.
                if peak.pass - pass >= 255 {
                    block.append(0xff)
                    block.appendLittleEndian(peak.pass)
                    pass = peak.pass
                }
                block.append(UInt8(peak.pass - pass))
                block.appendLittleEndian(peak.magnitude)
                block.appendLittleEndian(peak.bin)
                pass = peak.pass
            }
            body.appendLittleEndian(UInt32(0x6003_0040) + UInt32(band))
            body.appendLittleEndian(UInt32(block.count))
            body.append(block)
            body.append(contentsOf: [UInt8](repeating: 0, count: (4 - block.count % 4) % 4))
        }

        // The first block has no content, it only repeats the size of what follows the header.
        let sizeAfterHeader = UInt32(8 + body.count)
        var rest = Data()
        rest.appendLittleEndian(UInt32(0x9411_9c00))
        for _ in 0..<3 { rest.appendLittleEndian(UInt32(0)) }
        rest.appendLittleEndian(UInt32(3) << 27) // 16 kHz
        for _ in 0..<2 { rest.appendLittleEndian(UInt32(0)) }
        rest.appendLittleEndian(UInt32(sampleCount + Self.sampleRate * 24 / 100))
        rest.appendLittleEndian(UInt32((15 << 19) + 0x40000))
        rest.appendLittleEndian(UInt32(0x4000_0000))
        rest.appendLittleEndian(sizeAfterHeader)
        rest.append(body)

        // Past the first two header words, which are the magic number and this checksum of the rest.
        var sized = Data()
        sized.appendLittleEndian(sizeAfterHeader)
        sized.append(rest)
        var out = Data()
        out.appendLittleEndian(UInt32(0xcafe_2580))
        out.appendLittleEndian(Self.crc32(of: sized))
        out.append(sized)
        return out
    }

    public var uri: String { Self.prefix + data.base64EncodedString() }

    /// CRC-32 (the common one, as in zip and PNG).
    static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return ~crc
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        return value
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - Finding the peaks

/// Reads audio 128 samples at a time and keeps the last 256 spectra, because a peak is only known
/// to be one once the 46 windows after it have been heard.
private struct Analyzer {
    static let hop = 128
    private static let window = 2048
    private static let bins = 1025
    private static let rows = 256
    /// Windows heard after a peak before it is judged.
    private static let delay = 46

    private(set) var bands = [[SoundSignature.Peak]](repeating: [], count: 4)

    private var ring = [Float](repeating: 0, count: 2048)
    private var ringEnd = 0
    private var re = [Float](repeating: 0, count: 2048)
    private var im = [Float](repeating: 0, count: 2048)
    /// The power of each of the last 256 windows, a row of 1025 bins each.
    private var spectra = [Float](repeating: 0, count: 256 * 1025)
    /// The same, with each bin raised to the loudest of its neighbours in pitch and in time.
    private var spread = [Float](repeating: 0, count: 256 * 1025)
    /// Windows heard so far.
    private var heard = 0
    private let transform = Transform()

    mutating func add(_ chunk: ArraySlice<Float>) {
        // Whole numbers from -32768 to 32767, as the service's own app hears them.
        for sample in chunk {
            ring[ringEnd] = max(-32768, min(32767, (sample * 32768).rounded()))
            ringEnd = (ringEnd + 1) & 2047
        }
        // Oldest first, shaped by the window so its edges don't ring.
        for index in 0..<Self.window {
            re[index] = ring[(index + ringEnd) & 2047] * transform.window[index]
            im[index] = 0
        }
        transform.run(&re, &im)

        let row = (heard & 255) * Self.bins
        for bin in 0..<Self.bins {
            spectra[row + bin] = max((re[bin] * re[bin] + im[bin] * im[bin]) / 131_072, 1e-10)
        }
        spreadLatest(row: row)
        heard += 1
        if heard >= Self.delay { findPeaks() }
    }

    /// Takes the newest spectrum into `spread`: each bin the loudest of itself and the two above it,
    /// and then each of the windows 1, 3 and 6 back as loud as it, so a peak must stand out in time.
    private mutating func spreadLatest(row: Int) {
        for bin in 0..<Self.bins { spread[row + bin] = spectra[row + bin] }
        for bin in 0...1022 {
            spread[row + bin] = max(spread[row + bin], spread[row + bin + 1], spread[row + bin + 2])
        }
        for back in [1, 3, 6] {
            let earlier = ((heard - back) & 255) * Self.bins
            for bin in 0..<Self.bins {
                spread[earlier + bin] = max(spread[earlier + bin], spread[row + bin])
            }
        }
    }

    private mutating func findPeaks() {
        let judged = ((heard - Self.delay) & 255) * Self.bins
        let before = ((heard - 49) & 255) * Self.bins
        let aroundOffsets = [-10, -7, -4, -3, 1, 2, 5, 8]
        let otherWindows = [-53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249]
            .map { ((heard + $0) & 255) * Self.bins }
        let pass = UInt32(heard - Self.delay)

        for bin in 10...1014 {
            let power = spectra[judged + bin]
            // Loud enough, and no quieter than the same pitch just before it.
            guard power >= 1.0 / 64, power >= spread[before + bin - 1] else { continue }
            // The loudest around it in pitch...
            var loudestAround: Float = 0
            for offset in aroundOffsets { loudestAround = max(loudestAround, spread[before + bin + offset]) }
            guard power > loudestAround else { continue }
            // ...and in time.
            var loudestAnywhere = loudestAround
            for window in otherWindows { loudestAnywhere = max(loudestAnywhere, spread[window + bin - 1]) }
            guard power > loudestAnywhere else { continue }

            let magnitude = Self.level(power)
            let lower = Self.level(spectra[judged + bin - 1])
            let upper = Self.level(spectra[judged + bin + 1])
            let curvature = magnitude * 2 - lower - upper
            guard curvature > 0 else { continue }
            // Where between the bins the peak really sits, in 64ths of a bin.
            let shift = max(-64, min(64, (upper - lower) * 32 / curvature))
            let corrected = bin * 64 + Int(shift)
            let hertz = Int(Float(corrected) * (16_000.0 / 2 / 1024 / 64))
            let band: Int
            switch hertz {
            case 250...519: band = 0
            case 520...1449: band = 1
            case 1450...3499: band = 2
            case 3500...5500: band = 3
            default: continue
            }
            bands[band].append(.init(pass: pass, magnitude: UInt16(max(0, min(65_535, magnitude))), bin: UInt16(corrected)))
        }
    }

    /// The service's scale for how loud a bin is.
    private static func level(_ power: Float) -> Float {
        max(log(power), 1.0 / 64) * 1477.3 + 6144
    }
}

/// A 2048-point Fourier transform, with the Hanning window applied to the audio before it.
private struct Transform {
    let window: [Float]
    private let cosines: [Float]
    private let sines: [Float]
    private let reversed: [Int]

    init() {
        let size = 2048
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0 + 1) / Double(size + 1))) }
        cosines = (0..<size / 2).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sines = (0..<size / 2).map { Float(-sin(2 * Double.pi * Double($0) / Double(size))) }
        reversed = (0..<size).map { index in
            var value = index, result = 0
            for _ in 0..<11 {
                result = (result << 1) | (value & 1)
                value >>= 1
            }
            return result
        }
    }

    /// In place: `re` and `im` hold the audio and zeros going in, the spectrum coming out.
    func run(_ re: inout [Float], _ im: inout [Float]) {
        let size = 2048
        for index in 0..<size where reversed[index] > index {
            re.swapAt(index, reversed[index])
            im.swapAt(index, reversed[index])
        }
        var length = 2
        while length <= size {
            let half = length / 2, stride = size / length
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosines[k * stride], wi = sines[k * stride]
                    let a = start + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += length
            }
            length <<= 1
        }
    }
}
