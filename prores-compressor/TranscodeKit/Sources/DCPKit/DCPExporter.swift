import Accelerate
import AVFoundation
import CoreVideo
import Foundation
import TranscodeKit

public struct DCPSettings: Sendable, Equatable {
    public var contentTitle: String
    public var container: DCPContainer
    public var j2kBitsPerSecond: Int

    public init(contentTitle: String, container: DCPContainer, j2kBitsPerSecond: Int = 125_000_000) {
        self.contentTitle = contentTitle
        self.container = container
        self.j2kBitsPerSecond = j2kBitsPerSecond
    }
}

/// SMPTE 2K 24 fps unencrypted DCP.
///
/// Frame pipeline: hardware ProRes decode (16-bit RGBA) → aspect-fit into the
/// DCI container → Rec.709→X'Y'Z' 12-bit → DCI-profile JPEG 2000
/// (frame-parallel — this is the CPU-bound stage) → MXF wrap → ST 429 XML →
/// self-validation. Only 24.0/23.976 sources are accepted; 23.976 becomes 24
/// with the standard 0.1% audio pull-up.
public final class DCPExporter: Exporter {
    private let settings: DCPSettings

    public init(settings: DCPSettings) {
        self.settings = settings
    }

    public func export(source: ProbedSource,
                       onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        let is24 = abs(source.frameRate - 24.0) < 0.01
        let is23976 = abs(source.frameRate - 23.976) < 0.01
        guard is24 || is23976 else {
            throw ExportError.unsupportedSource(
                "DCP requires a 24 or 23.976 fps source; this file is \(source.frameRate) fps")
        }
        guard !source.isQuarterRotated else {
            throw ExportError.unsupportedSource(
                "this file carries 90°/270° rotation metadata, which DCP export doesn't support — bake the rotation into a new master first")
        }

        let folderURL = Self.makeFolderURL(for: source, settings: settings)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        } catch {
            throw ExportError.packagingFailed("cannot create \(folderURL.lastPathComponent): \(error.localizedDescription)")
        }

        do {
            let result = try await runPipeline(source: source, folderURL: folderURL,
                                               needsPullUp: is23976, onProgress: onProgress)
            return result
        } catch {
            try? FileManager.default.removeItem(at: folderURL)
            if error is CancellationError { throw ExportError.cancelled }
            throw error
        }
    }

    private func runPipeline(source: ProbedSource, folderURL: URL, needsPullUp: Bool,
                             onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        let container = settings.container
        let pictureUUID = UUID()
        let soundUUID = source.hasAudio ? UUID() : nil
        let pictureURL = folderURL.appendingPathComponent("j2c_\(DCPPackage.uuidString(pictureUUID)).mxf")
        let soundURL = soundUUID.map { folderURL.appendingPathComponent("pcm_\(DCPPackage.uuidString($0)).mxf") }

        // --- Video: decode → frame → color → J2K (parallel) → MXF ---
        onProgress(ExportProgress(fraction: 0, eta: nil, phase: "Encoding picture"))
        let frameCount = try await encodePicture(
            source: source, to: pictureURL, assetUUID: pictureUUID, onProgress: onProgress)
        guard frameCount > 0 else {
            throw ExportError.encodingFailed("no video frames were produced")
        }

        // --- Audio ---
        if let soundURL, let soundUUID {
            onProgress(ExportProgress(fraction: 0.93, eta: nil, phase: "Writing audio"))
            try writeAudio(source: source, to: soundURL, assetUUID: soundUUID,
                           frameCount: frameCount, needsPullUp: needsPullUp)
        }
        try Task.checkCancellation()

        // --- Packaging ---
        onProgress(ExportProgress(fraction: 0.97, eta: nil, phase: "Packaging"))
        _ = try DCPPackage.write(DCPPackage.Input(
            folderURL: folderURL,
            contentTitle: settings.contentTitle,
            container: container,
            pictureURL: pictureURL,
            pictureUUID: pictureUUID,
            soundURL: soundURL,
            soundUUID: soundUUID,
            frameCount: frameCount))

        // --- Self-validation (never skipped) ---
        onProgress(ExportProgress(fraction: 0.99, eta: nil, phase: "Verifying"))
        try DCPValidator.validate(folderURL: folderURL,
                                  expectedContainer: container,
                                  expectSound: soundUUID != nil)

        let totalBytes = Self.folderBytes(folderURL)
        onProgress(ExportProgress(fraction: 1, eta: 0, phase: "Done"))
        return ExportResult(outputURL: folderURL, outputBytes: totalBytes)
    }

    // MARK: - Picture

    private func encodePicture(source: ProbedSource, to pictureURL: URL, assetUUID: UUID,
                               onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> Int {
        let container = settings.container
        // Natural (PAR-corrected) size decides the framing; vImage stretches
        // the coded-size decoded buffers into it, flattening any anamorphic PAR.
        let geometry = FramingGeometry.fit(sourceWidth: source.naturalWidth,
                                           sourceHeight: source.naturalHeight,
                                           in: container)
        let encoder = J2KEncoder(width: container.width, height: container.height,
                                 bitsPerSecond: settings.j2kBitsPerSecond)
        let transform = ColorTransform()

        let asset = AVURLAsset(url: source.url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.readerFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBALE,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ExportError.readerFailed("cannot decode \(source.videoCodecName) to 16-bit RGBA")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "video read failed")
        }

        let estimatedFrames = max(1, Int((source.duration * source.frameRate).rounded()))
        let startedAt = Date()
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let frameFactory = FrameFactory(geometry: geometry, container: container, transform: transform)

        var writer: J2KMXFWriter?
        var framesWritten = 0

        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var nextFrameIndex = 0
                var inFlight = 0
                var reorderBuffer: [Int: Data] = [:]

                func submitNext() throws -> Bool {
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        throw ExportError.readerFailed("video sample had no pixel buffer")
                    }
                    let planes = try frameFactory.makePlanes(from: pixelBuffer)
                    let index = nextFrameIndex
                    nextFrameIndex += 1
                    group.addTask {
                        let data = try encoder.encode(xPlane: planes.x, yPlane: planes.y, zPlane: planes.z)
                        return (index, data)
                    }
                    return true
                }

                while inFlight < maxConcurrent, try submitNext() {
                    inFlight += 1
                }

                while inFlight > 0 {
                    guard let (index, data) = try await group.next() else { break }
                    inFlight -= 1
                    reorderBuffer[index] = data

                    try Task.checkCancellation()
                    if try submitNext() {
                        inFlight += 1
                    }

                    while let ready = reorderBuffer[framesWritten] {
                        reorderBuffer.removeValue(forKey: framesWritten)
                        if writer == nil {
                            writer = try J2KMXFWriter(url: pictureURL, assetUUID: assetUUID,
                                                      firstFrame: ready)
                        }
                        try writer?.write(frame: ready)
                        framesWritten += 1

                        if framesWritten % 24 == 0 {
                            let fraction = min(0.93, 0.93 * Double(framesWritten) / Double(estimatedFrames))
                            let elapsed = Date().timeIntervalSince(startedAt)
                            let eta: TimeInterval? = fraction > 0.01
                                ? elapsed * (0.93 - fraction) / fraction : nil
                            onProgress(ExportProgress(fraction: fraction, eta: eta,
                                                      phase: "Encoding picture"))
                        }
                    }
                }

                guard reorderBuffer.isEmpty else {
                    throw ExportError.encodingFailed("frame reordering failed (gap in encoded frames)")
                }
            }
        } catch {
            reader.cancelReading()
            throw error
        }

        if reader.status == .failed {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "video decode failed")
        }
        try writer?.finish()
        return framesWritten
    }

    // MARK: - Audio

    private func writeAudio(source: ProbedSource, to soundURL: URL, assetUUID: UUID,
                            frameCount: Int, needsPullUp: Bool) throws {
        let conformer = try AudioConformer(source: source, needsPullUp: needsPullUp)
        let writer = try PCMMXFWriter(url: soundURL, assetUUID: assetUUID,
                                      channelCount: AudioConformer.channelCount,
                                      sampleRate: AudioConformer.sampleRate)
        guard writer.bytesPerFrame == AudioConformer.bytesPerFrame else {
            throw ExportError.packagingFailed(
                "audio frame size mismatch: asdcplib expects \(writer.bytesPerFrame), producing \(AudioConformer.bytesPerFrame)")
        }
        for frameIndex in 0..<frameCount {
            if frameIndex % 240 == 0 {
                try Task.checkCancellation()
            }
            try writer.write(frame: try conformer.nextFrame())
        }
        try writer.finish()
    }

    // MARK: - Helpers

    private static func makeFolderURL(for source: ProbedSource, settings: DCPSettings) -> URL {
        let estimatedFrames = max(1, Int((source.duration * 24).rounded()))
        let name = DCPPackage.folderName(contentTitle: settings.contentTitle,
                                         container: settings.container,
                                         frameCount: estimatedFrames,
                                         hasAudio: source.hasAudio)
        let parent = source.url.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name)_\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private static func folderBytes(_ folderURL: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += (try? DCPPackage.fileSize(url)) ?? 0
        }
        return total
    }
}

/// Scales a decoded 16-bit RGBA frame into the DCI container and converts it
/// to X'Y'Z' planes. Sequential (runs on the coordinating task); the J2K
/// workers only see the finished planes.
private final class FrameFactory {
    struct Planes {
        let x: [UInt16]
        let y: [UInt16]
        let z: [UInt16]
    }

    private let geometry: FramingGeometry
    private let container: DCPContainer
    private let transform: ColorTransform
    private var scaleBuffer: UnsafeMutableRawPointer?
    private let scaleRowBytes: Int

    init(geometry: FramingGeometry, container: DCPContainer, transform: ColorTransform) {
        self.geometry = geometry
        self.container = container
        self.transform = transform
        scaleRowBytes = geometry.scaledWidth * 8
    }

    deinit {
        scaleBuffer?.deallocate()
    }

    func makePlanes(from pixelBuffer: CVPixelBuffer) throws -> Planes {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExportError.readerFailed("pixel buffer has no base address")
        }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let pixelCount = container.width * container.height
        var xPlane = [UInt16](repeating: 0, count: pixelCount)
        var yPlane = [UInt16](repeating: 0, count: pixelCount)
        var zPlane = [UInt16](repeating: 0, count: pixelCount)

        let needsScale = sourceWidth != geometry.scaledWidth || sourceHeight != geometry.scaledHeight
        let convertSource: UnsafeRawPointer
        let convertRowBytes: Int
        if needsScale {
            if scaleBuffer == nil {
                scaleBuffer = UnsafeMutableRawPointer.allocate(
                    byteCount: scaleRowBytes * geometry.scaledHeight, alignment: 64)
            }
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                       height: vImagePixelCount(sourceHeight),
                                       width: vImagePixelCount(sourceWidth),
                                       rowBytes: sourceRowBytes)
            var destination = vImage_Buffer(data: scaleBuffer,
                                            height: vImagePixelCount(geometry.scaledHeight),
                                            width: vImagePixelCount(geometry.scaledWidth),
                                            rowBytes: scaleRowBytes)
            let status = vImageScale_ARGB16U(&source, &destination, nil,
                                             vImage_Flags(kvImageHighQualityResampling))
            guard status == kvImageNoError else {
                throw ExportError.encodingFailed("vImage scale failed (\(status))")
            }
            convertSource = UnsafeRawPointer(scaleBuffer!)
            convertRowBytes = scaleRowBytes
        } else {
            convertSource = UnsafeRawPointer(base)
            convertRowBytes = sourceRowBytes
        }

        xPlane.withUnsafeMutableBufferPointer { xBuffer in
            yPlane.withUnsafeMutableBufferPointer { yBuffer in
                zPlane.withUnsafeMutableBufferPointer { zBuffer in
                    transform.convert(rgba: convertSource,
                                      width: geometry.scaledWidth,
                                      height: geometry.scaledHeight,
                                      rowBytes: convertRowBytes,
                                      xPlane: xBuffer.baseAddress!,
                                      yPlane: yBuffer.baseAddress!,
                                      zPlane: zBuffer.baseAddress!,
                                      planeWidth: container.width,
                                      xOffset: geometry.xOffset,
                                      yOffset: geometry.yOffset)
                }
            }
        }

        return Planes(x: xPlane, y: yPlane, z: zPlane)
    }
}
