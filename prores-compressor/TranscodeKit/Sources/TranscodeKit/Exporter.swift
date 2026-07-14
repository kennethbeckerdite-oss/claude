import CoreGraphics
import Foundation

/// Everything the exporters need to know about an input file, captured once
/// by `SourceProbe`. Value-only so it can cross concurrency domains; exporters
/// re-open the asset from `url`.
public struct ProbedSource: Sendable, Equatable {
    public let url: URL
    public let fileSizeBytes: Int64
    public let duration: Double

    public let videoCodecName: String
    public let isProRes: Bool
    /// Coded (stored) pixel dimensions — what the decoder emits.
    public let width: Int
    public let height: Int
    /// Display dimensions after pixel-aspect-ratio correction (the track's
    /// naturalSize), before rotation. Anamorphic sources have coded ≠ natural;
    /// exports must use these or the picture comes out squeezed.
    public let naturalWidth: Int
    public let naturalHeight: Int
    /// Rotation/flip metadata (e.g. phone footage); MP4 export passes it
    /// through, DCP export rejects rotated sources.
    public let preferredTransform: CGAffineTransform
    public let frameRate: Double
    public let bitDepth: Int

    /// CMFormatDescription color extension values (kCVImageBufferColorPrimaries…
    /// CFString constants), passed through to the MP4 writer when present.
    public let colorPrimaries: String?
    public let colorTransferFunction: String?
    public let colorYCbCrMatrix: String?

    public let hasAudio: Bool
    public let audioChannels: Int
    public let audioSampleRate: Double

    /// `naturalWidth`/`naturalHeight` after applying any 90°/270° rotation —
    /// what the viewer actually sees; use for UI and aspect decisions.
    public var displayWidth: Int {
        isQuarterRotated ? naturalHeight : naturalWidth
    }

    public var displayHeight: Int {
        isQuarterRotated ? naturalWidth : naturalHeight
    }

    public var isQuarterRotated: Bool {
        // 90°/270° transforms have zero on the diagonal.
        abs(preferredTransform.a) < 0.001 && abs(preferredTransform.d) < 0.001
    }

    public init(url: URL, fileSizeBytes: Int64, duration: Double,
                videoCodecName: String, isProRes: Bool,
                width: Int, height: Int,
                naturalWidth: Int, naturalHeight: Int,
                preferredTransform: CGAffineTransform,
                frameRate: Double, bitDepth: Int,
                colorPrimaries: String?, colorTransferFunction: String?, colorYCbCrMatrix: String?,
                hasAudio: Bool, audioChannels: Int, audioSampleRate: Double) {
        self.url = url
        self.fileSizeBytes = fileSizeBytes
        self.duration = duration
        self.videoCodecName = videoCodecName
        self.isProRes = isProRes
        self.width = width
        self.height = height
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.preferredTransform = preferredTransform
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.colorPrimaries = colorPrimaries
        self.colorTransferFunction = colorTransferFunction
        self.colorYCbCrMatrix = colorYCbCrMatrix
        self.hasAudio = hasAudio
        self.audioChannels = audioChannels
        self.audioSampleRate = audioSampleRate
    }
}

public struct ExportProgress: Sendable {
    /// 0...1 across the whole export.
    public let fraction: Double
    /// Estimated seconds remaining; nil until enough has run to extrapolate.
    public let eta: TimeInterval?
    /// Short human-readable phase, e.g. "Encoding video", "Writing audio".
    public let phase: String

    public init(fraction: Double, eta: TimeInterval?, phase: String) {
        self.fraction = fraction
        self.eta = eta
        self.phase = phase
    }
}

public struct ExportResult: Sendable {
    public let outputURL: URL
    public let outputBytes: Int64

    public init(outputURL: URL, outputBytes: Int64) {
        self.outputURL = outputURL
        self.outputBytes = outputBytes
    }
}

public enum ExportError: LocalizedError {
    case noVideoTrack
    case unsupportedSource(String)
    case readerFailed(String)
    case writerFailed(String)
    case encodingFailed(String)
    case packagingFailed(String)
    case validationFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The file has no video track."
        case .unsupportedSource(let reason):
            return "Unsupported source: \(reason)"
        case .readerFailed(let reason):
            return "Could not read the source: \(reason)"
        case .writerFailed(let reason):
            return "Could not write the output: \(reason)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .packagingFailed(let reason):
            return "Packaging failed: \(reason)"
        case .validationFailed(let reason):
            return "Output failed verification: \(reason)"
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

public protocol Exporter: Sendable {
    /// Runs the export to completion. Honors task cancellation by throwing
    /// `ExportError.cancelled` and removing partial output.
    func export(source: ProbedSource,
                onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult
}

public enum RenderSize {
    /// Fits dimensions within optional maximums, preserving aspect and never
    /// upscaling. Results are even (encoder requirement).
    public static func fit(width: Int, height: Int,
                           maxWidth: Int? = nil, maxHeight: Int? = nil) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (evened(max(2, width)), evened(max(2, height))) }
        var scale = 1.0
        if let maxWidth, maxWidth > 0 {
            scale = min(scale, Double(maxWidth) / Double(width))
        }
        if let maxHeight, maxHeight > 0 {
            scale = min(scale, Double(maxHeight) / Double(height))
        }
        let fittedWidth = max(2, Int((Double(width) * scale).rounded()))
        let fittedHeight = max(2, Int((Double(height) * scale).rounded()))
        return (evened(fittedWidth), evened(fittedHeight))
    }

    private static func evened(_ value: Int) -> Int {
        value - value % 2
    }
}

/// Picks a non-clobbering output URL next to the source:
/// "Name<suffix>.<ext>", then "Name<suffix> 2.<ext>", …
public func availableOutputURL(besides sourceURL: URL, suffix: String, pathExtension: String) -> URL {
    let dir = sourceURL.deletingLastPathComponent()
    let base = sourceURL.deletingPathExtension().lastPathComponent + suffix
    var candidate = dir.appendingPathComponent(base).appendingPathExtension(pathExtension)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base) \(counter)").appendingPathExtension(pathExtension)
        counter += 1
    }
    return candidate
}
