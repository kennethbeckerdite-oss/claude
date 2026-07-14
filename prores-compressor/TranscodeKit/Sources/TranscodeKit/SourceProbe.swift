import AVFoundation
import CoreMedia
import Foundation

public enum SourceProbe {
    /// Loads the metadata the exporters and UI need. Throws
    /// `ExportError.noVideoTrack` for files without video.
    public static func probe(url: URL) async throws -> ProbedSource {
        let asset = AVURLAsset(url: url)
        let (tracks, cmDuration) = try await asset.load(.tracks, .duration)

        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw ExportError.noVideoTrack
        }

        let (formatDescriptions, nominalFrameRate, naturalSize, preferredTransform) =
            try await videoTrack.load(.formatDescriptions, .nominalFrameRate,
                                      .naturalSize, .preferredTransform)
        guard let format = formatDescriptions.first else {
            throw ExportError.unsupportedSource("video track has no format description")
        }

        let codecType = CMFormatDescriptionGetMediaSubType(format)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)

        // naturalSize is PAR-corrected (anamorphic sources: coded ≠ natural)
        // but not rotation-corrected; fall back to coded dims if it's absent.
        var naturalWidth = Int(naturalSize.width.rounded())
        var naturalHeight = Int(naturalSize.height.rounded())
        if naturalWidth <= 0 || naturalHeight <= 0 {
            naturalWidth = Int(dimensions.width)
            naturalHeight = Int(dimensions.height)
        }
        naturalWidth -= naturalWidth % 2
        naturalHeight -= naturalHeight % 2

        var audioChannels = 0
        var audioSampleRate = 0.0
        if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            if let audioFormat = audioFormats.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee {
                audioChannels = Int(asbd.mChannelsPerFrame)
                audioSampleRate = asbd.mSampleRate
            }
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        return ProbedSource(
            url: url,
            fileSizeBytes: fileSize,
            duration: cmDuration.seconds,
            videoCodecName: Self.codecName(for: codecType),
            isProRes: Self.proResCodecs.keys.contains(codecType),
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            naturalWidth: naturalWidth,
            naturalHeight: naturalHeight,
            preferredTransform: preferredTransform,
            frameRate: Double(nominalFrameRate),
            bitDepth: Self.bitDepth(for: codecType, format: format),
            colorPrimaries: Self.extensionString(format, kCMFormatDescriptionExtension_ColorPrimaries),
            colorTransferFunction: Self.extensionString(format, kCMFormatDescriptionExtension_TransferFunction),
            colorYCbCrMatrix: Self.extensionString(format, kCMFormatDescriptionExtension_YCbCrMatrix),
            hasAudio: audioChannels > 0,
            audioChannels: audioChannels,
            audioSampleRate: audioSampleRate
        )
    }

    private static let proResCodecs: [CMVideoCodecType: String] = [
        kCMVideoCodecType_AppleProRes4444XQ: "Apple ProRes 4444 XQ",
        kCMVideoCodecType_AppleProRes4444: "Apple ProRes 4444",
        kCMVideoCodecType_AppleProRes422HQ: "Apple ProRes 422 HQ",
        kCMVideoCodecType_AppleProRes422: "Apple ProRes 422",
        kCMVideoCodecType_AppleProRes422LT: "Apple ProRes 422 LT",
        kCMVideoCodecType_AppleProRes422Proxy: "Apple ProRes 422 Proxy",
        kCMVideoCodecType_AppleProResRAW: "Apple ProRes RAW",
        kCMVideoCodecType_AppleProResRAWHQ: "Apple ProRes RAW HQ",
    ]

    private static func codecName(for codecType: CMVideoCodecType) -> String {
        if let name = proResCodecs[codecType] {
            return name
        }
        switch codecType {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        default:
            return fourCCString(codecType)
        }
    }

    private static func bitDepth(for codecType: CMVideoCodecType, format: CMFormatDescription) -> Int {
        if let depthNumber = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber {
            return depthNumber.intValue
        }
        switch codecType {
        case kCMVideoCodecType_AppleProRes4444XQ, kCMVideoCodecType_AppleProRes4444:
            return 12
        case kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy:
            return 10
        default:
            return 8
        }
    }

    private static func extensionString(_ format: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }
}
