import Foundation

/// A DCP edit rate (whole frames per second). SMPTE DCPs allow 24, 25, and
/// 30; fractional broadcast rates are conformed to their integer parent with
/// the standard 1000/1001 audio pull-up.
public struct EditRate: Sendable, Equatable {
    /// Whole frames per second: 24, 25, or 30.
    public let fps: Int

    public init(fps: Int) {
        self.fps = fps
    }

    public static let fps24 = EditRate(fps: 24)
    public static let fps25 = EditRate(fps: 25)
    public static let fps30 = EditRate(fps: 30)

    /// CPL/MXF rational, always `fps/1`.
    public var numerator: Int { fps }
    public var denominator: Int { 1 }

    /// Audio samples per picture frame at 48 kHz — integer for all supported
    /// rates (2000 / 1920 / 1600).
    public var audioSamplesPerFrame: Int { AudioConformer.sampleRate / fps }

    /// "24 1" etc. for CPL EditRate/FrameRate elements.
    public var xmlString: String { "\(numerator) \(denominator)" }

    /// Maps a probed source frame rate to a DCP edit rate and whether the
    /// audio needs the 0.1% pull-up. Returns nil for rates DCP can't carry.
    public static func forSource(frameRate: Double) -> (rate: EditRate, needsPullUp: Bool)? {
        if abs(frameRate - 24.0) < 0.01 { return (.fps24, false) }
        if abs(frameRate - 23.976) < 0.05 { return (.fps24, true) }
        if abs(frameRate - 25.0) < 0.01 { return (.fps25, false) }
        if abs(frameRate - 30.0) < 0.02 { return (.fps30, false) }
        if abs(frameRate - 29.97) < 0.05 { return (.fps30, true) }
        return nil
    }

    public static func isSupported(frameRate: Double) -> Bool {
        forSource(frameRate: frameRate) != nil
    }
}
