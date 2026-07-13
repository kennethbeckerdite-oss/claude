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
    public let width: Int
    public let height: Int
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

    public init(url: URL, fileSizeBytes: Int64, duration: Double,
                videoCodecName: String, isProRes: Bool,
                width: Int, height: Int, frameRate: Double, bitDepth: Int,
                colorPrimaries: String?, colorTransferFunction: String?, colorYCbCrMatrix: String?,
                hasAudio: Bool, audioChannels: Int, audioSampleRate: Double) {
        self.url = url
        self.fileSizeBytes = fileSizeBytes
        self.duration = duration
        self.videoCodecName = videoCodecName
        self.isProRes = isProRes
        self.width = width
        self.height = height
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
