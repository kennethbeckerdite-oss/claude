import Foundation

/// Pure math for hitting a target file size with a single-pass ABR encode.
public enum BitrateCalculator {
    /// Fraction of the target budget handed to the encoder. Absorbs MP4
    /// container overhead and hardware-ABR drift so real output lands at or
    /// under the requested size.
    public static let defaultSafetyFactor = 0.97

    /// Hardware encoders produce unusable output below this; also guards
    /// against absurd inputs (tiny target, enormous duration).
    public static let minimumVideoBitsPerSecond = 500_000

    /// Video bits/second that fills `targetBytes` over `durationSeconds`
    /// after reserving room for audio and container overhead.
    public static func videoBitsPerSecond(targetBytes: Int64,
                                          durationSeconds: Double,
                                          audioBitsPerSecond: Int,
                                          safetyFactor: Double = defaultSafetyFactor) -> Int {
        guard durationSeconds > 0, targetBytes > 0 else {
            return minimumVideoBitsPerSecond
        }
        let totalBits = Double(targetBytes) * 8 * safetyFactor
        let audioBits = Double(audioBitsPerSecond) * durationSeconds
        let videoBits = (totalBits - audioBits) / durationSeconds
        return max(minimumVideoBitsPerSecond, Int(videoBits))
    }

    /// Rough output size for a given video bitrate — the inverse of
    /// `videoBitsPerSecond`, used by the UI to preview the estimate.
    public static func estimatedOutputBytes(videoBitsPerSecond: Int,
                                            durationSeconds: Double,
                                            audioBitsPerSecond: Int,
                                            safetyFactor: Double = defaultSafetyFactor) -> Int64 {
        guard durationSeconds > 0, safetyFactor > 0 else { return 0 }
        let bits = Double(videoBitsPerSecond + audioBitsPerSecond) * durationSeconds / safetyFactor
        return Int64(bits / 8)
    }
}
