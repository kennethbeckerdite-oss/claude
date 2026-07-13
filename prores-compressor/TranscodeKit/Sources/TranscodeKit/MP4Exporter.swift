import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public struct MP4Settings: Sendable, Equatable {
    public enum Codec: String, CaseIterable, Sendable {
        case hevc = "HEVC (H.265)"
        case h264 = "H.264"
    }

    public var targetBytes: Int64
    public var codec: Codec
    public var audioBitsPerSecond: Int

    public init(targetBytes: Int64, codec: Codec = .hevc, audioBitsPerSecond: Int = 256_000) {
        self.targetBytes = targetBytes
        self.codec = codec
        self.audioBitsPerSecond = audioBitsPerSecond
    }
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
    private let onProgress: @Sendable (ExportProgress) -> Void
    private let outputURL: URL

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderTrackOutput?
    private let audioInput: AVAssetWriterInput?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ExportResult, Error>?
    private var pendingInputs = 0
    private var cancelled = false
    private var startedAt = Date()

    init(source: ProbedSource, settings: MP4Settings, outputURL: URL,
         onProgress: @escaping @Sendable (ExportProgress) -> Void) throws {
        self.source = source
        self.onProgress = onProgress
        self.outputURL = outputURL

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

        // --- Video ---
        let pixelFormat: OSType = source.bitDepth >= 10
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false

        let videoBitrate = BitrateCalculator.videoBitsPerSecond(
            targetBytes: settings.targetBytes,
            durationSeconds: source.duration,
            audioBitsPerSecond: source.hasAudio ? settings.audioBitsPerSecond : 0)

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
            AVVideoWidthKey: source.width,
            AVVideoHeightKey: source.height,
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

        pump(input: videoInput, output: videoOutput,
             queue: DispatchQueue(label: "mp4export.video"), reportsProgress: true)
        if let audioInput, let audioOutput {
            pump(input: audioInput, output: audioOutput,
                 queue: DispatchQueue(label: "mp4export.audio"), reportsProgress: false)
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
                self.onProgress(ExportProgress(fraction: 1, eta: 0, phase: "Done"))
                self.finish(.success(ExportResult(outputURL: self.outputURL, outputBytes: bytes)))
            default:
                let message = self.writer.error?.localizedDescription ?? "unknown"
                self.finish(.failure(ExportError.writerFailed(message)))
            }
        }
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
