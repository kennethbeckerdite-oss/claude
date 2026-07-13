import AVFoundation
import Foundation
import TranscodeKit

/// Decodes the source audio into DCP edit-unit frames: 24-bit little-endian
/// PCM, 48 kHz, 6 channels (L R C LFE Ls Rs) with source stereo in L/R and
/// digital silence elsewhere — the 5.1 padding cinema servers expect.
///
/// 23.976 fps sources are conformed to 24 fps by resampling the audio 0.1%
/// shorter (the standard pull-up): the decoded 48 kHz stream is relabeled
/// 48048 Hz and converted back to 48 kHz.
public final class AudioConformer {
    public static let channelCount = 6
    public static let sampleRate = 48_000
    public static let bytesPerSample = 3
    /// 48000 / 24 fps.
    public static let samplesPerFrame = 2_000
    public static let bytesPerFrame = samplesPerFrame * channelCount * bytesPerSample

    private let reader: AVAssetReader?
    private let output: AVAssetReaderTrackOutput?
    private let converter: AVAudioConverter?
    private let converterOutputFormat: AVAudioFormat?

    /// Decoded-but-not-yet-framed interleaved stereo samples.
    private var pendingSamples: [Float] = []
    private var sourceExhausted: Bool

    public init(source: ProbedSource, needsPullUp: Bool) throws {
        guard source.hasAudio else {
            reader = nil
            output = nil
            converter = nil
            converterOutputFormat = nil
            sourceExhausted = true
            return
        }

        let asset = AVURLAsset(url: source.url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ExportError.readerFailed("audio track disappeared between probe and export")
        }

        let assetReader: AVAssetReader
        do {
            assetReader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.readerFailed(error.localizedDescription)
        }

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        trackOutput.alwaysCopiesSampleData = false
        guard assetReader.canAdd(trackOutput) else {
            throw ExportError.readerFailed("cannot convert the audio track to 48 kHz stereo PCM")
        }
        assetReader.add(trackOutput)
        guard assetReader.startReading() else {
            throw ExportError.readerFailed(assetReader.error?.localizedDescription ?? "audio read failed")
        }

        if needsPullUp {
            // Relabel 48000 → 48048 on input so the converter removes one
            // sample per thousand (the 1000/1001 conform).
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: 48_048, channels: 2, interleaved: true),
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: Double(Self.sampleRate),
                                                   channels: 2, interleaved: true),
                  let audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ExportError.unsupportedSource("cannot build the 23.976→24 audio conform converter")
            }
            converter = audioConverter
            converterOutputFormat = outputFormat
        } else {
            converter = nil
            converterOutputFormat = nil
        }

        reader = assetReader
        output = trackOutput
        sourceExhausted = false
    }

    /// Returns the next edit-unit frame (`bytesPerFrame` bytes), padding the
    /// tail with silence so exactly `remainingFrames` more frames can always
    /// be produced. Call once per video frame.
    public func nextFrame() throws -> Data {
        while pendingSamples.count < Self.samplesPerFrame * 2, !sourceExhausted {
            try readMore()
        }

        let stereoCount = Self.samplesPerFrame * 2
        var stereo = [Float](repeating: 0, count: stereoCount)
        let available = min(stereoCount, pendingSamples.count)
        if available > 0 {
            stereo.replaceSubrange(0..<available, with: pendingSamples[0..<available])
            pendingSamples.removeFirst(available)
        }

        return Self.packFrame(stereo: stereo)
    }

    private func readMore() throws {
        guard let reader, let output else {
            sourceExhausted = true
            return
        }
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw ExportError.readerFailed(reader.error?.localizedDescription ?? "audio decode failed")
            }
            try drainConverter()
            sourceExhausted = true
            return
        }

        guard let samples = Self.floatSamples(from: sample) else { return }
        if converter != nil {
            try convert(samples)
        } else {
            pendingSamples.append(contentsOf: samples)
        }
    }

    private func convert(_ samples: [Float], drain: Bool = false) throws {
        guard let converter, let outputFormat = converterOutputFormat else { return }
        let inputFormat = converter.inputFormat

        var inputBuffer: AVAudioPCMBuffer?
        if !samples.isEmpty {
            let frameCount = AVAudioFrameCount(samples.count / 2)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
                throw ExportError.encodingFailed("audio buffer allocation failed")
            }
            buffer.frameLength = frameCount
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            inputBuffer = buffer
        }

        let outputCapacity = AVAudioFrameCount(max(1024, samples.count / 2 + 64))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw ExportError.encodingFailed("audio buffer allocation failed")
        }

        var pendingInput = inputBuffer
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
            if let buffer = pendingInput {
                pendingInput = nil
                statusPointer.pointee = .haveData
                return buffer
            }
            statusPointer.pointee = drain ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            throw ExportError.encodingFailed(conversionError?.localizedDescription ?? "audio conform failed")
        }

        let produced = Int(outputBuffer.frameLength) * 2
        if produced > 0, let channel = outputBuffer.floatChannelData?[0] {
            pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: produced))
        }
    }

    private func drainConverter() throws {
        guard converter != nil else { return }
        try convert([], drain: true)
    }

    /// Interleaved stereo float → one 6-channel 24-bit LE edit unit.
    static func packFrame(stereo: [Float]) -> Data {
        var frame = Data(count: bytesPerFrame)
        frame.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            for sampleIndex in 0..<samplesPerFrame {
                let left = quantize24(stereo[sampleIndex * 2])
                let right = quantize24(stereo[sampleIndex * 2 + 1])
                let base = sampleIndex * channelCount * bytesPerSample
                writeSample(left, to: bytes + base)
                writeSample(right, to: bytes + base + bytesPerSample)
                // Channels 3–6 (C, LFE, Ls, Rs) stay zero — digital silence.
            }
        }
        return frame
    }

    @inline(__always)
    static func quantize24(_ value: Float) -> Int32 {
        let clamped = max(-1.0, min(1.0, Double(value)))
        return Int32((clamped * 8_388_607.0).rounded())
    }

    @inline(__always)
    private static func writeSample(_ value: Int32, to destination: UnsafeMutablePointer<UInt8>) {
        let bits = UInt32(bitPattern: value)
        destination[0] = UInt8(bits & 0xFF)
        destination[1] = UInt8((bits >> 8) & 0xFF)
        destination[2] = UInt8((bits >> 16) & 0xFF)
    }

    private static func floatSamples(from sample: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length >= MemoryLayout<Float>.size else { return nil }
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length,
                                       destination: destination.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : nil
    }
}
