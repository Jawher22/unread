import Foundation

/// The WAV parser from GVoiceKit's `RefLoudness`, which `QwenVoicePrep` reads a reference with.
/// Unread keeps only this part (lines 113-176 upstream); the loudness standard itself is not used.
public enum RefLoudness {

    /// Sample format of a `data` chunk this scaler understands.
    public enum SampleFormat: Equatable {
        /// WAVE_FORMAT_PCM, 16-bit signed little-endian.
        case pcm16
        /// WAVE_FORMAT_IEEE_FLOAT, 32-bit little-endian. The LuxTTS lane writes
        /// its derived reference window in this format (engines/lux-tts/ref.wav),
        /// and that is the file the engine actually renders from — so a standard
        /// that only understood PCM16 would silently skip exactly the asset that
        /// matters for a cloned voice.
        case float32
    }

    /// Byte range of the `data` chunk and its format.
    /// Walks the RIFF chunk list rather than assuming a 44-byte header: a WAV
    /// may legally carry LIST/fact/cue chunks before `data`, and an offset
    /// guessed from the canonical layout would scale header bytes as if they
    /// were audio.
    public static func dataChunk(in wav: Data) -> (offset: Int, length: Int, format: SampleFormat,
                                            sampleRate: Int, channels: Int)? {
        guard wav.count >= 12,
              wav[wav.startIndex ..< wav.startIndex + 4].elementsEqual(Array("RIFF".utf8)),
              wav[wav.startIndex + 8 ..< wav.startIndex + 12].elementsEqual(Array("WAVE".utf8))
        else { return nil }

        func u16(_ at: Int) -> Int { Int(wav[at]) | (Int(wav[at + 1]) << 8) }
        func u32(_ at: Int) -> Int {
            Int(wav[at]) | (Int(wav[at + 1]) << 8) | (Int(wav[at + 2]) << 16) | (Int(wav[at + 3]) << 24)
        }

        var bitsPerSample = 0
        var formatTag = 0
        var sampleRate = 0
        var channels = 0
        var i = wav.startIndex + 12
        while i + 8 <= wav.endIndex {
            let id = String(decoding: wav[i ..< i + 4], as: UTF8.self)
            let size = u32(i + 4)
            let body = i + 8
            guard size >= 0, body + size <= wav.endIndex else { return nil }
            if id == "fmt " , size >= 16 {
                formatTag = u16(body)
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bitsPerSample = u16(body + 14)
            } else if id == "data" {
                // Loudness weighting is frequency-dependent, so a missing or
                // nonsense sample rate makes the measurement meaningless rather
                // than merely approximate — refuse instead of guessing 44100.
                guard sampleRate > 0, channels > 0 else { return nil }
                // 1 == WAVE_FORMAT_PCM, 3 == WAVE_FORMAT_IEEE_FLOAT. Anything else
                // (ADPCM, extensible) is not what this scaler assumes, so leave it.
                if formatTag == 1, bitsPerSample == 16 {
                    return (body, size, .pcm16, sampleRate, channels)
                }
                if formatTag == 3, bitsPerSample == 32 {
                    return (body, size, .float32, sampleRate, channels)
                }
                return nil
            }
            i = body + size + (size % 2)   // chunks are word-aligned
        }
        return nil
    }
}
