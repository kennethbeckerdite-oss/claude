import XCTest
@testable import TranscodeKit

final class BitrateCalculatorTests: XCTestCase {
    func testTargetsFourGBForNinetyMinutes() {
        let bitrate = BitrateCalculator.videoBitsPerSecond(
            targetBytes: 4 * 1_000_000_000,
            durationSeconds: 90 * 60,
            audioBitsPerSecond: 256_000)
        // (4e9 * 8 * 0.97 - 256000 * 5400) / 5400 = 5,492,148 b/s
        XCTAssertEqual(Double(bitrate), 5_492_148, accuracy: 2)
    }

    func testEstimateInvertsToTarget() {
        let target: Int64 = 3 * 1_000_000_000
        let duration = 45.0 * 60
        let audio = 256_000
        let bitrate = BitrateCalculator.videoBitsPerSecond(
            targetBytes: target, durationSeconds: duration, audioBitsPerSecond: audio)
        let estimate = BitrateCalculator.estimatedOutputBytes(
            videoBitsPerSecond: bitrate, durationSeconds: duration, audioBitsPerSecond: audio)
        XCTAssertEqual(Double(estimate), Double(target), accuracy: Double(target) * 0.001)
    }

    func testNeverReturnsBelowMinimum() {
        // A 2 GB target over 100 hours is below the usable floor.
        let bitrate = BitrateCalculator.videoBitsPerSecond(
            targetBytes: 2 * 1_000_000_000,
            durationSeconds: 100 * 3600,
            audioBitsPerSecond: 256_000)
        XCTAssertEqual(bitrate, BitrateCalculator.minimumVideoBitsPerSecond)
    }

    func testDegenerateInputsFallBackToMinimum() {
        XCTAssertEqual(
            BitrateCalculator.videoBitsPerSecond(targetBytes: 0, durationSeconds: 60, audioBitsPerSecond: 0),
            BitrateCalculator.minimumVideoBitsPerSecond)
        XCTAssertEqual(
            BitrateCalculator.videoBitsPerSecond(targetBytes: 1_000_000, durationSeconds: 0, audioBitsPerSecond: 0),
            BitrateCalculator.minimumVideoBitsPerSecond)
    }

    func testNoAudioLeavesFullBudgetForVideo() {
        let duration = 600.0
        let withAudio = BitrateCalculator.videoBitsPerSecond(
            targetBytes: 2_000_000_000, durationSeconds: duration, audioBitsPerSecond: 256_000)
        let withoutAudio = BitrateCalculator.videoBitsPerSecond(
            targetBytes: 2_000_000_000, durationSeconds: duration, audioBitsPerSecond: 0)
        XCTAssertEqual(withoutAudio - withAudio, 256_000)
    }
}
