import XCTest
@testable import TranscodeKit

final class LoudnessMeterTests: XCTestCase {
    private let sampleRate = 48_000.0

    /// The K-weighting filters must reproduce the published ITU-R BS.1770-4
    /// 48 kHz reference coefficients.
    func testKWeightingCoefficientsMatchITU() {
        let s1 = Biquad.kWeightingStage1(sampleRate: 48_000)
        XCTAssertEqual(s1.b0, 1.53512485958697, accuracy: 1e-6)
        XCTAssertEqual(s1.b1, -2.69169618940638, accuracy: 1e-6)
        XCTAssertEqual(s1.b2, 1.19839281085285, accuracy: 1e-6)
        XCTAssertEqual(s1.a1, -1.69065929318241, accuracy: 1e-6)
        XCTAssertEqual(s1.a2, 0.73248077421585, accuracy: 1e-6)

        let s2 = Biquad.kWeightingStage2(sampleRate: 48_000)
        XCTAssertEqual(s2.a1, -1.99004745483398, accuracy: 1e-6)
        XCTAssertEqual(s2.a2, 0.99007225036621, accuracy: 1e-6)
    }

    func testSilenceIsUnmeasured() {
        let meter = LoudnessMeter(channelCount: 2, sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: 2 * Int(sampleRate)) // 1 s stereo
        meter.add(silence, frameCount: Int(sampleRate))
        XCTAssertNil(meter.integratedLUFS())
    }

    /// Doubling amplitude must raise integrated loudness by ~6.02 LU.
    func testDoublingAmplitudeAddsSixLU() {
        let quiet = measureSine(frequency: 1000, amplitude: 0.25, seconds: 3)
        let loud = measureSine(frequency: 1000, amplitude: 0.5, seconds: 3)
        XCTAssertNotNil(quiet)
        XCTAssertNotNil(loud)
        XCTAssertEqual(loud! - quiet!, 6.02, accuracy: 0.1)
    }

    /// K-weighting boosts presence-band content: a 3 kHz tone must read louder
    /// than a 100 Hz tone of equal amplitude.
    func testKWeightingBoostsHighFrequencies() {
        let low = measureSine(frequency: 100, amplitude: 0.5, seconds: 3)
        let high = measureSine(frequency: 3000, amplitude: 0.5, seconds: 3)
        XCTAssertNotNil(low)
        XCTAssertNotNil(high)
        XCTAssertGreaterThan(high!, low! + 3.0)
    }

    /// A full-scale 1 kHz sine lands in a sane range (guards gross calibration
    /// errors); pyloudnorm reports ≈ +3.0 LUFS for this signal.
    func testFullScaleToneInExpectedRange() {
        let lufs = measureSine(frequency: 1000, amplitude: 1.0, seconds: 3)
        XCTAssertNotNil(lufs)
        XCTAssertEqual(lufs!, 3.0, accuracy: 1.0)
    }

    func testLFEIsExcludedFromSurroundMeasurement() {
        // A 5.1 frame with signal only in LFE (index 3) must be unmeasured —
        // LFE has weight 0 in BS.1770.
        let meter = LoudnessMeter(channelCount: 6, sampleRate: sampleRate)
        let frames = Int(sampleRate) * 3
        var interleaved = [Float](repeating: 0, count: frames * 6)
        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            interleaved[frame * 6 + 3] = Float(0.5 * sin(2 * .pi * 100 * t))
        }
        meter.add(interleaved, frameCount: frames)
        XCTAssertNil(meter.integratedLUFS(), "LFE-only signal must not register loudness")
    }

    // MARK: - Helpers

    private func measureSine(frequency: Double, amplitude: Double, seconds: Double) -> Double? {
        let meter = LoudnessMeter(channelCount: 2, sampleRate: sampleRate)
        let frames = Int(sampleRate * seconds)
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            let value = Float(amplitude * sin(2 * .pi * frequency * t))
            interleaved[frame * 2] = value
            interleaved[frame * 2 + 1] = value
        }
        meter.add(interleaved, frameCount: frames)
        return meter.integratedLUFS()
    }
}
