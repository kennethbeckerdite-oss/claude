import Foundation

/// Streaming integrated-loudness meter per ITU-R BS.1770-4 (the EBU R128
/// measurement). K-weighting → 400 ms gating blocks at 75% overlap →
/// two-stage gate (−70 LKFS absolute, then −10 LU relative). Advisory only:
/// the app measures and reports LUFS, it never alters audio.
///
/// Feed interleaved float samples as they stream; call `integratedLUFS()`
/// once at the end. Coefficients are computed for the given sample rate, so
/// any rate works (48 kHz reproduces the ITU reference coefficients).
public final class LoudnessMeter {
    private let channelCount: Int
    /// Per-channel BS.1770 weights (L/R/C = 1, LFE = 0, surrounds = 1.41).
    private let weights: [Double]
    private let blockSize: Int
    private let hopSize: Int

    private var stage1: [Biquad]
    private var stage2: [Biquad]

    /// Ring buffer of K-weighted squared samples per channel, plus running sum.
    private var ring: [[Double]]
    private var ringIndex = 0
    private var ringSum: [Double]
    private var samplesInRing = 0
    private var samplesSinceBlock = 0

    /// Per-block weighted power (Σ_ch weight·meanSquare) — the gating input.
    private var blockPowers: [Double] = []

    public init(channelCount: Int, sampleRate: Double, weights: [Double]? = nil) {
        precondition(channelCount > 0, "loudness meter needs at least one channel")
        self.channelCount = channelCount
        self.weights = weights ?? Self.defaultWeights(channelCount: channelCount)
        blockSize = max(1, Int((0.4 * sampleRate).rounded()))
        hopSize = max(1, blockSize / 4) // 75% overlap
        stage1 = (0..<channelCount).map { _ in Biquad.kWeightingStage1(sampleRate: sampleRate) }
        stage2 = (0..<channelCount).map { _ in Biquad.kWeightingStage2(sampleRate: sampleRate) }
        ring = Array(repeating: [Double](repeating: 0, count: blockSize), count: channelCount)
        ringSum = [Double](repeating: 0, count: channelCount)
    }

    /// Standard channel weights by count. 6 channels are assumed SMPTE order
    /// L R C LFE Ls Rs; stereo/mono weight everything 1.0.
    public static func defaultWeights(channelCount: Int) -> [Double] {
        if channelCount >= 6 {
            var w = [Double](repeating: 1.0, count: channelCount)
            w[3] = 0.0    // LFE excluded
            w[4] = 1.41   // Ls
            w[5] = 1.41   // Rs
            return w
        }
        return [Double](repeating: 1.0, count: channelCount)
    }

    /// Feeds `frameCount` interleaved sample frames (channelCount values each).
    public func add(interleaved samples: UnsafeBufferPointer<Float>, frameCount: Int) {
        for frame in 0..<frameCount {
            let base = frame * channelCount
            for channel in 0..<channelCount {
                let filtered = stage2[channel].process(stage1[channel].process(Double(samples[base + channel])))
                let squared = filtered * filtered
                let old = ring[channel][ringIndex]
                ring[channel][ringIndex] = squared
                ringSum[channel] += squared - old
            }
            ringIndex = (ringIndex + 1) % blockSize
            if samplesInRing < blockSize { samplesInRing += 1 }

            samplesSinceBlock += 1
            if samplesSinceBlock >= hopSize, samplesInRing >= blockSize {
                samplesSinceBlock = 0
                var power = 0.0
                for channel in 0..<channelCount {
                    power += weights[channel] * (ringSum[channel] / Double(blockSize))
                }
                blockPowers.append(power)
            }
        }
    }

    public func add(_ samples: [Float], frameCount: Int) {
        samples.withUnsafeBufferPointer { add(interleaved: $0, frameCount: frameCount) }
    }

    /// Integrated loudness (LUFS), or nil if no block passed the absolute gate
    /// (e.g. silence or too-short audio).
    public func integratedLUFS() -> Double? {
        guard !blockPowers.isEmpty else { return nil }

        // Absolute gate at −70 LKFS.
        let absoluteThresholdPower = powerFor(loudness: -70.0)
        let absoluteGated = blockPowers.filter { $0 > absoluteThresholdPower }
        guard !absoluteGated.isEmpty else { return nil }

        // Relative gate: −10 LU below the mean loudness of the absolute-gated set.
        let meanAbsolutePower = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeThresholdPower = powerFor(loudness: loudnessFor(power: meanAbsolutePower) - 10.0)
        let gated = absoluteGated.filter { $0 > relativeThresholdPower }
        guard !gated.isEmpty else { return nil }

        let meanGatedPower = gated.reduce(0, +) / Double(gated.count)
        return loudnessFor(power: meanGatedPower)
    }

    /// LKFS ↔ power (the −0.691 dB absolute calibration from BS.1770).
    private func loudnessFor(power: Double) -> Double {
        power > 0 ? -0.691 + 10 * log10(power) : -.infinity
    }

    private func powerFor(loudness: Double) -> Double {
        pow(10, (loudness + 0.691) / 10)
    }
}

/// Transposed Direct Form II biquad (a0 normalized to 1).
struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// BS.1770-4 pre-filter (high-shelf head effect). At 48 kHz this reproduces
    /// the ITU reference coefficients (b0 ≈ 1.53512, a1 ≈ −1.69066…).
    static func kWeightingStage1(sampleRate fs: Double) -> Biquad {
        let db = 3.999843853973347
        let q = 0.7071752369554196
        let fc = 1681.9744509555319
        let k = tan(.pi * fc / fs)
        let vh = pow(10.0, db / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1.0 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2.0 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0)
    }

    /// BS.1770-4 RLB high-pass (stage 2).
    static func kWeightingStage2(sampleRate fs: Double) -> Biquad {
        let q = 0.5003270373238773
        let fc = 38.13547087602444
        let k = tan(.pi * fc / fs)
        let a0 = 1.0 + k / q + k * k
        return Biquad(
            b0: 1.0,
            b1: -2.0,
            b2: 1.0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0)
    }
}

/// Advisory interpretation of an integrated LUFS reading for the QC report.
public enum LoudnessAdvice {
    public static func describe(lufs: Double?) -> String {
        guard let lufs else { return "not measured (silent or too short)" }
        let value = String(format: "%.1f LUFS integrated", lufs)
        // Cinema mixes typically sit well below streaming's ~−14 LUFS target;
        // a DCP near web levels will be uncomfortably loud in a theater.
        if lufs > -16 {
            return value + "  ⚠️ near web/streaming levels — likely too hot for a theater; have the mix checked"
        }
        if lufs > -20 {
            return value + "  (louder than typical theatrical; fine for web/screener)"
        }
        return value
    }
}
