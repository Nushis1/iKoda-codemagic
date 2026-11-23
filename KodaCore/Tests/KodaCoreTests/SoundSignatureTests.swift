import Foundation
import Testing
@testable import KodaCore

@Suite struct SoundSignatureTests {
    @Test func theChecksumIsTheCommonCRC32() {
        // The standard check value of CRC-32.
        #expect(SoundSignature.crc32(of: Data("123456789".utf8)) == 0xcbf4_3926)
    }

    @Test func silenceHasNoPeaks() {
        let signature = SoundSignature(samples: [Float](repeating: 0, count: 16_000 * 12))
        #expect(signature.peakCount == 0)
        #expect(signature.milliseconds == 12_000)
    }

    @Test func aSignatureIsLaidOutAsTheServiceReadsIt() {
        let peak = { (pass: UInt32, magnitude: UInt16, bin: UInt16) in SoundSignature.Peak(pass: pass, magnitude: magnitude, bin: bin) }
        let signature = SoundSignature(sampleCount: 16_000 * 3, bands: [
            [peak(1, 100, 30), peak(300, 200, 40)], [peak(2, 110, 60)], [], [peak(5, 120, 900)],
        ])
        let data = signature.data
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
        }
        #expect(word(0) == 0xcafe_2580)
        #expect(word(8) == UInt32(data.count - 48))
        #expect(word(12) == 0x9411_9c00)
        #expect(word(28) == 3 << 27)
        #expect(word(40) == 16_000 * 3 + 3840)
        #expect(word(44) == 0x7c0000)
        #expect(word(48) == 0x4000_0000)
        #expect(word(52) == UInt32(data.count - 48))
        // The checksum covers everything after the first eight bytes.
        #expect(word(4) == SoundSignature.crc32(of: data.dropFirst(8)))
        // The first band: 250-520 Hz, with 2 peaks of 5 bytes, then a jump of 299 windows written whole.
        #expect(word(56) == 0x6003_0040)
        #expect(word(60) == 5 + 1 + 4 + 5)
        // Blocks are padded to four bytes.
        #expect(data.count % 4 == 0)
        #expect(signature.uri.hasPrefix("data:audio/vnd.shazam.sig;base64,"))
    }
}
