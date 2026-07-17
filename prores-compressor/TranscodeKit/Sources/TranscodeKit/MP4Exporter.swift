import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public struct MP4Settings: Sendable, Equatable {
    public enum Codec: String, CaseIterable, Sendable {
        case hevc = "HEVC (H.265)"
        case h264 = "H.264"
    }

    public enum RateControl: Sendable, Equatable {
        /// Bitrate computed to land the whole file at (or just under) `bytes`.
        case targetSize(bytes: Int64)
        /// Fixed average video bitrate, independent of duration.
        case averageBitrate(bitsPerSecond: Int)
    }

    public var rateControl: RateControl
    public var codec: Codec
    public var audioBitsPerSecond: Int
    /// Downscale-to-fit bounds (aspect preserved, never upscales). nil = keep
    /// the source's natural size.
    public var maxWidth: Int?
    public var maxHeight: Int?
    /// Optional .srt to burn into the picture. When set (and it has cues), the
    /// video is decoded to 8-bit BGRA, captions drawn per frame, then encoded.
    public var subtitleURL: URL?

    public init(rateControl: RateControl, codec: Codec = .hevc,
                audioBitsPerSecond: Int = 256_000,
                maxWidth: Int? = nil, maxHeight: Int? = nil,
                subtitleURL: URL? = nil) {
        self.rateControl = rateControl
        self.codec = codec
        self.audioBitsPerSecond = audioBitsPerSecond
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.subtitleURL = subtitleURL
    }

    /// Port of Kenneth's HandBrake "MP4 Small & HQ" preset: H.264 High,
    /// 6 Mb/s average, capped at 1920×1080 without upscaling, AAC stereo
    /// 160 kb/s. (x264 placebo/tune/2-pass have no VideoToolbox equivalent;
    /// the delivery envelope is what carries over.)
    public static let smallHQ = MP4Settings(
        rateControl: .averageBitrate(bitsPerSecond: 6_000_000),
        codec: .h264,
        audioBitsPerSecond: 160_000,
        maxWidth: 1920,
        maxHeight: 1080)

    /// Festival submission preset: "2 GB or under" with headroom for upload
    /// size checks, H.264 so any screener laptop/TV plays it, capped at 1080p.
    public static let festivalShort = MP4Settings(
        rateControl: .targetSize(bytes: 1_900_000_000),
        codec: .h264,
        audioBitsPerSecond: 160_000,
        maxWidth: 1920,
        maxHeight: 1080)
}

public final class MP4Exporter: Exporter {
    private let settings: MP4Settings

    public init(settings: MP4Settings) {
        self.settings = settings
    }

    public func export(source: ProbedSource,
                       onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        let outputURL = availableOutputURL(besides: source.url, suffix: " (compressed)", pathExtension: "mp4")
        let session = try MP4ExportSession(source: source, settings: settings,
                                           outputURL: outputURL, onProgress: onProgress)
        do {
            return try await session.run()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

/// One-shot reader→writer pump. Reference type because AVAssetReader/Writer
/// and the completion continuation are shared across the pump queues and the
/// cancellation handler; all mutable state is guarded by `lock`.
private final class MP4ExportSession: @unchecked Sendable {
    private let source: ProbedSource
    private let settings: MP4Settings
    private let onProgress: @Sendable (ExportProgress) -> Void
    private let outputURL: URL
    private let videoBitrate: Int
    private let outputSize: (width: Int, height: Int)

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderTrackOutput?
    private let audioInput: AVAssetWriterInput?
    /// Non-nil only when burning subtitles; drives the BGRA draw-and-append path.
    private let burner: SubtitleBurner?
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ExportResult, Error>?
    private var pendingInputs = 0
    private var cancelled = false
    private var startedAt = Date()
    private var audioPeak: Float = 0
    /// Touched only on the audio pump queue; read after writing finishes.
    private let loudnessMeter: LoudnessMeter?

    init(source: ProbedSource, settings: MP4Settings, outputURL: URL,
         onProgress: @escaping @Sendable (ExportProgress) -> Void) throws {
        self.source = source
        self.settings = settings
        self.onProgress = onProgress
        self.outputURL = outputURL
        // Reader delivers source-rate/channel interleaved float PCM; meter it
        // as-is (advisory — for >2ch the source channel order is assumed).
        loudnessMeter = source.hasAudio
            ? LoudnessMeter(channelCount: max(1, source.audioChannels),
                            sampleRate: source.audioSampleRate > 0 ? source.audioSampleRate : 48_000)
            : nil

        let asset = AVURLAsset(url: source.url)
        // Tracks were loaded by SourceProbe; the synchronous accessor is safe here.
        let videoTracks = asset.tracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ExportError.noVideoTrack
        }

        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ExportError.writerFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        // --- Subtitles (optional) ---
        // Burning captions forces an 8-bit BGRA decode/draw/encode path; when
        // there are no cues we keep the fast hardware passthrough.
        if let subtitleURL = settings.subtitleURL,
           let cues = try? SRTParser.parse(url: subtitleURL), !cues.isEmpty {
            burner = SubtitleBurner(cues: cues)
        } else {
            burner = nil
        }
        let burningSubtitles = burner != nil

        // --- Video ---
        let pixelFormat: OSType
        if burningSubtitles {
            pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            pixelFormat = source.bitDepth >= 10
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        // Burn path draws into the buffer, so it needs a mutable copy.
        videoOutput.alwaysCopiesSampleData = burningSubtitles

        switch settings.rateControl {
        case .targetSize(let bytes):
            videoBitrate = BitrateCalculator.videoBitsPerSecond(
                targetBytes: bytes,
                durationSeconds: source.duration,
                audioBitsPerSecond: source.hasAudio ? settings.audioBitsPerSecond : 0)
        case .averageBitrate(let bitsPerSecond):
            videoBitrate = max(BitrateCalculator.minimumVideoBitsPerSecond, bitsPerSecond)
        }

        // Natural (PAR-corrected) size, not coded size — anamorphic sources
        // export squeezed otherwise. Optionally fitted into the preset bounds.
        outputSize = RenderSize.fit(width: source.naturalWidth, height: source.naturalHeight,
                                    maxWidth: settings.maxWidth, maxHeight: settings.maxHeight)

        let frameRate = source.frameRate > 0 ? source.frameRate : 24
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
            AVVideoMaxKeyFrameIntervalKey: max(1, Int((frameRate * 2).rounded())),
        ]
        let codecType: AVVideoCodecType
        switch settings.codec {
        case .hevc:
            codecType = .hevc
            if source.bitDepth >= 10 {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            }
        case .h264:
            codecType = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: outputSize.width,
            AVVideoHeightKey: outputSize.height,
            // Stretch decoded (coded-size) buffers to the PAR-corrected output
            // frame; aspect is already correct because outputSize derives from
            // naturalSize.
            AVVideoScalingModeKey: AVVideoScalingModeResize,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let primaries = source.colorPrimaries,
           let transfer = source.colorTransferFunction,
           let matrix = source.colorYCbCrMatrix {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ]
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Carry rotation/flip metadata (e.g. phone footage) instead of baking
        // it into pixels.
        videoInput.transform = source.preferredTransform

        if burningSubtitles {
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: source.width,
                    kCVPixelBufferHeightKey as String: source.height,
                ])
        } else {
            pixelBufferAdaptor = nil
        }

        // --- Audio (AAC stereo) ---
        if source.hasAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            output.alwaysCopiesSampleData = false

            var stereoLayout = AudioChannelLayout()
            stereoLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let sampleRate = (source.audioSampleRate > 0 && source.audioSampleRate <= 48_000)
                ? source.audioSampleRate : 48_000
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: min(2, max(1, source.audioChannels)),
                AVEncoderBitRateKey: settings.audioBitsPerSecond,
                AVChannelLayoutKey: withUnsafeBytes(of: &stereoLayout) { Data($0) },
            ])
            input.expectsMediaDataInRealTime = false
            audioOutput = output
            audioInput = input
        } else {
            audioOutput = nil
            audioInput = nil
        }

        guard reader.canAdd(videoOutput) else {
            throw ExportError.readerFailed("cannot decode \(source.videoCodecName) video")
        }
        reader.add(videoOutput)
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerFailed("cannot encode with the chosen settings")
        }
        writer.add(videoInput)

        if let audioOutput, let audioInput {
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else {
                throw ExportError.readerFailed("cannot convert the audio track")
            }
            reader.add(audioOutput)
            writer.add(audioInput)
        }
    }

    func run() async throws -> ExportResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<ExportResult, Error>) {
        lock.lock()
        self.continuation = continuation
        self.startedAt = Date()
        self.pendingInputs = 1 + (audioInput != nil ? 1 : 0)
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled {
            finish(.failure(ExportError.cancelled))
            return
        }

        guard writer.startWriting() else {
            finish(.failure(ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")))
            return
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            finish(.failure(ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")))
            return
        }
        writer.startSession(atSourceTime: .zero)

        pumpVideo(queue: DispatchQueue(label: "mp4export.video"))
        if let audioInput, let audioOutput {
            pump(input: audioInput, output: audioOutput,
                 queue: DispatchQueue(label: "mp4export.audio"), reportsProgress: false)
        }
    }

    private func pumpVideo(queue: DispatchQueue) {
        videoInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            while self.videoInput.isReadyForMoreMediaData {
                guard let sample = self.videoOutput.copyNextSampleBuffer() else {
                    self.videoInput.markAsFinished()
                    self.inputFinished()
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let appended: Bool
                if let burner = self.burner, let adaptor = self.pixelBufferAdaptor,
                   let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                    burner.draw(into: pixelBuffer, at: pts.seconds)
                    appended = adaptor.append(pixelBuffer, withPresentationTime: pts)
                } else {
                    appended = self.videoInput.append(sample)
                }
                guard appended else {
                    self.reader.cancelReading()
                    let message = self.writer.error?.localizedDescription ?? "encoder rejected samples"
                    self.finish(.failure(ExportError.encodingFailed(message)))
                    return
                }
                self.reportProgress(at: pts)
            }
        }
    }

    private func pump(input: AVAssetWriterInput, output: AVAssetReaderTrackOutput,
                      queue: DispatchQueue, reportsProgress: Bool) {
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    self.inputFinished()
                    return
                }
                guard input.append(sample) else {
                    self.reader.cancelReading()
                    let message = self.writer.error?.localizedDescription ?? "encoder rejected samples"
                    self.finish(.failure(ExportError.encodingFailed(message)))
                    return
                }
                if reportsProgress {
                    self.reportProgress(at: CMSampleBufferGetPresentationTimeStamp(sample))
                } else {
                    self.trackAudioPeak(in: sample)
                }
            }
        }
    }

    private func reportProgress(at timestamp: CMTime) {
        guard source.duration > 0 else { return }
        let fraction = min(1, max(0, timestamp.seconds / source.duration))
        lock.lock()
        let elapsed = Date().timeIntervalSince(startedAt)
        lock.unlock()
        let eta: TimeInterval? = fraction > 0.02 ? elapsed * (1 - fraction) / fraction : nil
        onProgress(ExportProgress(fraction: fraction, eta: eta, phase: "Encoding video"))
    }

    /// Reader delivers float32 interleaved PCM (per outputSettings), so a
    /// straight scan over the block buffer gives the sample peak.
    private func trackAudioPeak(in sample: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length >= MemoryLayout<Float>.size else { return }
        let floatCount = length / MemoryLayout<Float>.size
        var peak: Float = 0
        pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
            for index in 0..<floatCount {
                let magnitude = abs(floats[index])
                if magnitude > peak { peak = magnitude }
            }
            if let meter = loudnessMeter, source.audioChannels > 0 {
                meter.add(interleaved: UnsafeBufferPointer(start: floats, count: floatCount),
                          frameCount: floatCount / source.audioChannels)
            }
        }
        lock.lock()
        if peak > audioPeak { audioPeak = peak }
        lock.unlock()
    }

    private func inputFinished() {
        lock.lock()
        pendingInputs -= 1
        let allDone = pendingInputs == 0
        lock.unlock()
        guard allDone else { return }

        if reader.status == .failed {
            writer.cancelWriting()
            finish(.failure(ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")))
            return
        }
        if reader.status == .cancelled {
            writer.cancelWriting()
            finish(.failure(ExportError.cancelled))
            return
        }
        writer.finishWriting { [weak self] in
            guard let self else { return }
            switch self.writer.status {
            case .completed:
                let bytes = (try? self.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .flatMap { Int64($0) } ?? 0
                let qcURL = self.writeQCReport(outputBytes: bytes)
                self.onProgress(ExportProgress(fraction: 1, eta: 0, phase: "Done"))
                self.finish(.success(ExportResult(outputURL: self.outputURL, outputBytes: bytes,
                                                  qcReportURL: qcURL)))
            default:
                let message = self.writer.error?.localizedDescription ?? "unknown"
                self.finish(.failure(ExportError.writerFailed(message)))
            }
        }
    }

    private func writeQCReport(outputBytes: Int64) -> URL? {
        var report = QCReport(title: "QC Report — \(outputURL.lastPathComponent)")
        report.sections.append(QCReport.sourceSection(source))

        var outputLines = [
            "File: \(outputURL.lastPathComponent)",
            "Container: MP4 (faststart)",
            "Video: \(settings.codec.rawValue)"
                + (settings.codec == .hevc && source.bitDepth >= 10 ? " Main10" : ""),
            "Dimensions: \(outputSize.width)×\(outputSize.height)",
            String(format: "Video bitrate: %.2f Mb/s average", Double(videoBitrate) / 1_000_000),
            "Size: \(ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)) (\(outputBytes) bytes)",
        ]
        if case .targetSize(let target) = settings.rateControl {
            outputLines.append("Target size: \(ByteCountFormatter.string(fromByteCount: target, countStyle: .file))"
                + (outputBytes <= target ? " — met" : " — EXCEEDED, re-check"))
        }
        if let burner {
            outputLines.append("Subtitles: burned in from SRT (\(burner.cueCount) cues)")
        }
        report.add("Output", outputLines)

        if source.hasAudio {
            lock.lock()
            let peak = audioPeak
            lock.unlock()
            let lufs = loudnessMeter?.integratedLUFS()
            let loudnessLabel = source.audioChannels > 2 ? " (source, approximate)" : ""
            report.add("Audio", [
                "AAC stereo \(settings.audioBitsPerSecond / 1000) kb/s",
                "Peak: \(QCReport.formatPeak(dbfs: peak > 0 ? 20 * log10(Double(peak)) : nil))",
                "Loudness\(loudnessLabel): \(LoudnessAdvice.describe(lufs: lufs, context: .screener))",
            ])
        }

        let qcURL = outputURL.deletingPathExtension().appendingPathExtension("QC.txt")
        return report.write(to: qcURL)
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        // Makes copyNextSampleBuffer return nil; the pump then unwinds through
        // inputFinished(), sees .cancelled, and resumes the continuation.
        reader.cancelReading()
    }

    private func finish(_ result: Result<ExportResult, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
