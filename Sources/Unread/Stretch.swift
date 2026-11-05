import Accelerate

/// Pitch-preserving time stretch (WSOLA): the narrator has no speed control of its own. `AVAudioUnitTimePitch` (offline rendering)
/// glitched at chunk joins unless held ~8k samples behind the input, which would delay first
/// audio by ~0.3 s.
struct TimeStretch {
    let rate: Double
    static let frame = 720, hop = 360, search = 256
    private static let window = (0..<frame).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frame))) }
    private var input: [Float] = []
    private var output: [Float] = []
    private var emitted = 0
    private var frameIndex = 0
    private var previous: Int?

    init(rate: Double) { self.rate = rate }

    mutating func push(_ chunk: [Float]) -> [Float] {
        input += chunk
        return run(until: .max)
    }

    mutating func finish() -> [Float] {
        let total = Int((Double(input.count) / rate).rounded())
        input += [Float](repeating: 0, count: Self.frame + 2 * Self.search + 2 * Self.hop)
        return run(until: total)
    }

    private mutating func run(until total: Int) -> [Float] {
        let n = Self.frame, hop = Self.hop
        var out: [Float] = []
        while emitted < total {
            let due = Int((Double(frameIndex * hop) * rate).rounded())
            // Below 1×, the frame continuing the previous one can reach past the search window.
            guard due + Self.search + n <= input.count, previous.map({ $0 + hop + n <= input.count }) ?? true else { break }
            let lo = max(due - Self.search, 0)
            let from = previous.map { lo + bestMatch(continuing: $0 + hop, from: lo, count: due + Self.search - lo + 1) } ?? due
            let at = frameIndex * hop
            if output.count < at + n { output += [Float](repeating: 0, count: at + n - output.count) }
            input.withUnsafeBufferPointer { i in
                output.withUnsafeMutableBufferPointer { o in
                    vDSP_vma(i.baseAddress! + from, 1, Self.window, 1, o.baseAddress! + at, 1, o.baseAddress! + at, 1, vDSP_Length(n))
                }
            }
            previous = from
            frameIndex += 1
            let ready = min(frameIndex * hop, total)
            if ready > emitted { out += output[emitted..<ready]; emitted = ready }
        }
        return out
    }

    private func bestMatch(continuing target: Int, from lo: Int, count: Int) -> Int {
        let n = Self.frame
        var correlation = [Float](repeating: 0, count: count)
        var energy: Float = 0
        input.withUnsafeBufferPointer { i in
            vDSP_conv(i.baseAddress! + lo, 1, i.baseAddress! + target, 1, &correlation, 1, vDSP_Length(count), vDSP_Length(n))
            vDSP_svesq(i.baseAddress! + lo, 1, &energy, vDSP_Length(n))
        }
        var best = 0, bestScore = -Float.infinity
        for j in 0..<count {
            let score = correlation[j] / (energy + 1e-6).squareRoot()
            if score > bestScore { bestScore = score; best = j }
            if j + 1 < count { energy = max(energy - input[lo + j] * input[lo + j] + input[lo + j + n] * input[lo + j + n], 0) }
        }
        return best
    }
}
