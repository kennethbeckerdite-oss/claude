import AVFoundation
import Foundation
import TranscodeKit

/// Decodes the source audio into DCP edit-unit frames: 24-bit little-endian
/// PCM, 48 kHz, 6 channels in SMPTE order (L R C LFE Ls Rs).
///
/// - Sources with ≥6 channels pass through as 5.1: channels are mapped into
///   SMPTE order using the file's channel labels; if the file carries no
///   usable layout the stored order is kept and flagged for the QC report.
/// - Mono/stereo sources land in L/R with digital silence elsewhere
///   (the 5.1 padding cinema servers expect).
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

    /// Output slot order is SMPTE: L R C LFE Ls Rs. `map[slot]` = source
    /// channel index feeding that slot, nil = silence.
    struct ChannelMap {
        let slots: [Int?]
        let description: String
        /// False when the source order had to be trusted blindly.
        let verified: Bool

        static func make(sourceChannels: Int, labels: [UInt32]) -> ChannelMap {
            if sourceChannels < 6 {
                return ChannelMap(
                    slots: [0, sourceChannels >= 2 ? 1 : 0, nil, nil, nil, nil],
                    description: sourceChannels >= 2
                        ? "stereo source mapped to L/R, other channels silent"
                        : "mono source duplicated to L/R, other channels silent",
                    verified: true)
            }

            // AudioChannelLabel raw values (CoreAudioTypes):
            // 1 Left, 2 Right, 3 Center, 4 LFEScreen,
            // 5 LeftSurround, 6 RightSurround, 33/34 RearSurroundLeft/Right.
            func find(_ candidates: [UInt32]) -> Int? {
                for candidate in candidates {
                    if let index = labels.firstIndex(of: candidate) {
                        return index
                    }
                }
                return nil
            }

            let resolved: [Int?] = [
                find([1]),        // L
                find([2]),        // R
                find([3]),        // C
                find([4]),        // LFE
                find([5, 33]),    // Ls
                find([6, 34]),    // Rs
            ]

            if labels.count >= 6, resolved.allSatisfy({ $0 != nil }) {
                return ChannelMap(slots: resolved,
                                  description: "5.1 source mapped by channel labels to L R C LFE Ls Rs",
                                  verified: true)
            }
            return ChannelMap(slots: [0, 1, 2, 3, 4, 5],
                              description: "6-channel source passed through in stored order (no usable channel labels — verify L R C LFE Ls Rs)",
                              verified: false)
        }
    }

    private let reader: AVAssetReader?
    private let output: AVAssetReaderTrackOutput?
    private let converter: AVAudioConverter?
    private let converterOutputFormat: AVAudioFormat?
    /// Channels delivered by the reader (2 or 6).
    private let readChannels: Int
    let channelMap: ChannelMap

    /// Decoded-but-not-yet-framed interleaved samples (readChannels per frame).
    private var pendingSamples: [Float] = []
    private var sourceExhausted: Bool

    /// Loudest absolute sample seen across all source channels (0…1+).
    public private(set) var peakSample: Float = 0

    /// Sample peak in dBFS, nil until audio has been read (or if silent).
    public var peakDBFS: Double? {
        peakSample > 0 ? 20 * log10(Double(peakSample)) : nil
    }

    public var channelMappingDescription: String { channelMap.description }
    public var channelMappingVerified: Bool { channelMap.verified }

    public init(source: ProbedSource, needsPullUp: Bool) throws {
        channelMap = ChannelMap.make(sourceChannels: source.audioChannels,
                                     labels: source.audioChannelLabels)
        readChannels = source.audioChannels >= 6 ? 6 : 2

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
            AVNumberOfChannelsKey: readChannels,
        ])
        trackOutput.alwaysCopiesSampleData = false
        guard assetReader.canAdd(trackOutput) else {
            throw ExportError.readerFailed("cannot convert the audio track to 48 kHz \(readChannels)-channel PCM")
        }
        assetReader.add(trackOutput)
        guard assetReader.startReading() else {
            throw ExportError.readerFailed(assetReader.error?.localizedDescription ?? "audio read failed")
        }

        if needsPullUp {
            // Relabel 48000 → 48048 on input so the converter removes one
            // sample per thousand (the 1000/1001 conform).
            guard let inputFormat = Self.interleavedFloatFormat(sampleRate: 48_048, channels: readChannels),
                  let outputFormat = Self.interleavedFloatFormat(sampleRate: Double(Self.sampleRate),
                                                                 channels: readChannels),
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

    /// AVAudioFormat needs an explicit channel layout above 2 channels.
    private static func interleavedFloatFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: AVAudioChannelCount(channels), interleaved: true)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A) else {
            return nil
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                             interleaved: true, channelLayout: layout)
    }

    /// Returns the next edit-unit frame (`bytesPerFrame` bytes), padding the
    /// tail with silence. Call once per video frame.
    public func nextFrame() throws -> Data {
        let needed = Self.samplesPerFrame * readChannels
        while pendingSamples.count < needed, !sourceExhausted {
            try readMore()
        }

        var sourceFrame = [Float](repeating: 0, count: needed)
        let available = min(needed, pendingSamples.count)
        if available > 0 {
            sourceFrame.replaceSubrange(0..<available, with: pendingSamples[0..<available])
            pendingSamples.removeFirst(available)
        }

        return packFrame(sourceInterleaved: sourceFrame)
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
            appendPending(samples)
        }
    }

    private func appendPending<S: Sequence>(_ samples: S) where S.Element == Float {
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peakSample {
                peakSample = magnitude
            }
            pendingSamples.append(sample)
        }
    }

    private func convert(_ samples: [Float], drain: Bool = false) throws {
        guard let converter, let outputFormat = converterOutputFormat else { return }
        let inputFormat = converter.inputFormat
        let channels = readChannels

        var inputBuffer: AVAudioPCMBuffer?
        if !samples.isEmpty {
            let frameCount = AVAudioFrameCount(samples.count / channels)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
                throw ExportError.encodingFailed("audio buffer allocation failed")
            }
            buffer.frameLength = frameCount
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            inputBuffer = buffer
        }

        let outputCapacity = AVAudioFrameCount(max(1024, samples.count / channels + 64))
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

        let produced = Int(outputBuffer.frameLength) * channels
        if produced > 0, let channel = outputBuffer.floatChannelData?[0] {
            appendPending(UnsafeBufferPointer(start: channel, count: produced))
        }
    }

    private func drainConverter() throws {
        guard converter != nil else { return }
        try convert([], drain: true)
    }

    /// Interleaved source floats (readChannels per sample frame) → one
    /// 6-channel 24-bit LE edit unit in SMPTE slot order.
    func packFrame(sourceInterleaved: [Float]) -> Data {
        let channels = readChannels
        let slots = channelMap.slots
        var frame = Data(count: Self.bytesPerFrame)
        frame.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            for sampleIndex in 0..<Self.samplesPerFrame {
                let sourceBase = sampleIndex * channels
                let destinationBase = sampleIndex * Self.channelCount * Self.bytesPerSample
                for slot in 0..<Self.channelCount {
                    guard let sourceChannel = slots[slot], sourceChannel < channels else { continue }
                    let value = Self.quantize24(sourceInterleaved[sourceBase + sourceChannel])
                    Self.writeSample(value, to: bytes + destinationBase + slot * Self.bytesPerSample)
                }
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
