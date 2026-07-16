import Accelerate
import AVFoundation
import CoreVideo
import Foundation
import TranscodeKit

/// One video in a DCP package. Each element becomes its own composition (CPL).
public struct DCPElement: Sendable {
    public var source: ProbedSource
    public var title: String

    public init(source: ProbedSource, title: String) {
        self.source = source
        self.title = title
    }
}

public struct DCPSettings: Sendable {
    public var contentTitle: String
    public var container: DCPContainer
    public var j2kBitsPerSecond: Int
    public var dcnc: DCNCOptions
    /// Additional videos for a multi-composition package. When empty, the
    /// single `source` passed to `export` is the only composition.
    public var elements: [DCPElement]

    public init(contentTitle: String, container: DCPContainer,
                j2kBitsPerSecond: Int = 125_000_000, dcnc: DCNCOptions = DCNCOptions(),
                elements: [DCPElement] = []) {
        self.contentTitle = contentTitle
        self.container = container
        self.j2kBitsPerSecond = j2kBitsPerSecond
        self.dcnc = dcnc
        self.elements = elements
    }
}

/// SMPTE 2K unencrypted DCP (24/25/30 fps).
///
/// Frame pipeline per composition: hardware ProRes decode (16-bit RGBA) →
/// aspect-fit into the DCI container → Rec.709→X'Y'Z' 12-bit → DCI-profile
/// JPEG 2000 (frame-parallel, the CPU-bound stage) → MXF wrap → ST 429 XML →
/// self-validation. Fractional source rates (23.976, 29.97) are conformed to
/// their integer parent with the standard 0.1% audio pull-up. A package may
/// hold several compositions, each its own CPL/title on the cinema server.
public final class DCPExporter: Exporter {
    private let settings: DCPSettings

    public init(settings: DCPSettings) {
        self.settings = settings
    }

    private struct ElementResult {
        let composition: DCPPackage.Composition
        let source: ProbedSource
        let editRate: EditRate
        let audioQC: AudioQC?
    }

    public func export(source: ProbedSource,
                       onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        let elements = settings.elements.isEmpty
            ? [DCPElement(source: source, title: settings.contentTitle)]
            : settings.elements

        // Resolve each element's edit rate + validate up front, before any work.
        var resolved: [(element: DCPElement, editRate: EditRate, needsPullUp: Bool)] = []
        for element in elements {
            guard let mapping = EditRate.forSource(frameRate: element.source.frameRate) else {
                throw ExportError.unsupportedSource(
                    "\(element.source.url.lastPathComponent): DCP supports 24/25/30 fps (incl. 23.976/29.97); this file is \(element.source.frameRate) fps")
            }
            guard !element.source.isQuarterRotated else {
                throw ExportError.unsupportedSource(
                    "\(element.source.url.lastPathComponent) carries 90°/270° rotation metadata, which DCP export doesn't support — bake the rotation into a new master first")
            }
            resolved.append((element, mapping.rate, mapping.needsPullUp))
        }

        let folderURL = Self.makeFolderURL(firstSource: elements[0].source,
                                           firstTitle: elements[0].title, settings: settings)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        } catch {
            throw ExportError.packagingFailed("cannot create \(folderURL.lastPathComponent): \(error.localizedDescription)")
        }

        do {
            return try await runPackage(resolved: resolved, folderURL: folderURL, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: folderURL)
            if error is CancellationError { throw ExportError.cancelled }
            throw error
        }
    }

    private func runPackage(resolved: [(element: DCPElement, editRate: EditRate, needsPullUp: Bool)],
                            folderURL: URL,
                            onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        let container = settings.container

        // Weight progress by each element's duration; reserve the last 4% for
        // packaging + validation.
        let durations = resolved.map { max(0.001, $0.element.source.duration) }
        let totalDuration = durations.reduce(0, +)
        let encodeBudget = 0.96
        var elapsedFraction = 0.0

        var results: [ElementResult] = []
        for (index, entry) in resolved.enumerated() {
            let slice = encodeBudget * durations[index] / totalDuration
            let sliceStart = elapsedFraction
            elapsedFraction += slice
            let elementLabel = resolved.count > 1 ? " (\(index + 1)/\(resolved.count))" : ""

            let result = try await encodeElement(
                entry.element, editRate: entry.editRate, needsPullUp: entry.needsPullUp,
                index: index, folderURL: folderURL) { local in
                    onProgress(ExportProgress(fraction: sliceStart + slice * local.fraction,
                                              eta: nil,
                                              phase: local.phase + elementLabel))
                }
            results.append(result)
            try Task.checkCancellation()
        }

        // --- Packaging ---
        onProgress(ExportProgress(fraction: 0.97, eta: nil, phase: "Packaging"))
        let packageOutput = try DCPPackage.writePackage(
            folderURL: folderURL, compositions: results.map(\.composition))

        // On non-APFS volumes (exFAT/NTFS) macOS stores extended attributes
        // as "._" AppleDouble siblings; cinema servers flag them as foreign
        // files, so strip them before validating.
        Self.removeAppleDoubleFiles(in: folderURL)

        // --- Self-validation (never skipped) ---
        onProgress(ExportProgress(fraction: 0.99, eta: nil, phase: "Verifying"))
        let expectSound = results.contains { $0.composition.soundUUID != nil }
        let validation = try DCPValidator.validate(folderURL: folderURL,
                                                   expectedContainer: container,
                                                   expectSound: expectSound)

        let totalBytes = Self.folderBytes(folderURL)
        let qcURL = writeQCReport(folderURL: folderURL, results: results,
                                  totalBytes: totalBytes,
                                  assetHashes: packageOutput.assetHashes, validation: validation)
        onProgress(ExportProgress(fraction: 1, eta: 0, phase: "Done"))
        return ExportResult(outputURL: folderURL, outputBytes: totalBytes, qcReportURL: qcURL)
    }

    private struct AudioQC {
        let peakDBFS: Double?
        let loudnessLUFS: Double?
        let mappingDescription: String
        let mappingVerified: Bool
    }

    /// Encodes one element into its picture (+ sound) MXF and returns the
    /// composition metadata for packaging. `onProgress` reports element-local
    /// fraction 0…1.
    private func encodeElement(_ element: DCPElement, editRate: EditRate, needsPullUp: Bool,
                               index: Int, folderURL: URL,
                               onProgress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ElementResult {
        let source = element.source
        let pictureUUID = UUID()
        let soundUUID = source.hasAudio ? UUID() : nil
        // Filenames carry the UUID, so multiple compositions never collide.
        let pictureURL = folderURL.appendingPathComponent("j2c_\(DCPPackage.uuidString(pictureUUID)).mxf")
        let soundURL = soundUUID.map { folderURL.appendingPathComponent("pcm_\(DCPPackage.uuidString($0)).mxf") }

        onProgress(ExportProgress(fraction: 0, eta: nil, phase: "Encoding picture"))
        let frameCount = try await encodePicture(
            source: source, editRate: editRate, to: pictureURL, assetUUID: pictureUUID) { fraction in
                onProgress(ExportProgress(fraction: fraction * 0.95, eta: nil, phase: "Encoding picture"))
            }
        guard frameCount > 0 else {
            throw ExportError.encodingFailed("no video frames were produced")
        }

        var audioQC: AudioQC?
        if let soundURL, let soundUUID {
            onProgress(ExportProgress(fraction: 0.96, eta: nil, phase: "Writing audio"))
            audioQC = try writeAudio(source: source, editRate: editRate, to: soundURL,
                                     assetUUID: soundUUID, frameCount: frameCount, needsPullUp: needsPullUp)
        }

        let dcncName = DCPPackage.folderName(
            contentTitle: element.title, container: settings.container,
            frameCount: frameCount, hasAudio: source.hasAudio, options: settings.dcnc)
        let composition = DCPPackage.Composition(
            dcncName: dcncName,
            contentTitle: element.title,
            contentKind: settings.dcnc.resolvedKind(frameCount: frameCount).contentKind,
            container: settings.container,
            editRate: editRate,
            pictureURL: pictureURL,
            pictureUUID: pictureUUID,
            soundURL: soundURL,
            soundUUID: soundUUID,
            frameCount: frameCount)

        return ElementResult(composition: composition, source: source,
                             editRate: editRate, audioQC: audioQC)
    }

    private func writeQCReport(folderURL: URL, results: [ElementResult],
                               totalBytes: Int64,
                               assetHashes: [(name: String, sha1: String)],
                               validation: DCPValidator.Report) -> URL? {
        let folderName = folderURL.lastPathComponent
        var report = QCReport(title: "QC Report — \(folderName)")

        report.add("Package", [
            "Folder: \(folderName)",
            "Standard: SMPTE, unencrypted, 2K",
            "Container: \(settings.container.displayName)",
            "Compositions: \(results.count)",
            String(format: "JPEG 2000 bitrate cap: %.0f Mb/s", Double(settings.j2kBitsPerSecond) / 1_000_000),
            "Total size: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))",
        ])

        for (index, result) in results.enumerated() {
            let composition = result.composition
            let fps = result.editRate.fps
            report.sections.append(QCReport.sourceSection(result.source))
            var lines = [
                "Title: \(composition.contentTitle)",
                "DCNC: \(composition.dcncName)",
                "Kind: \(composition.contentKind)",
                "Picture: \(composition.frameCount) frames @ \(fps) fps (\(String(format: "%.2f", Double(composition.frameCount) / Double(fps))) s)",
            ]
            if let audioQC = result.audioQC {
                lines.append("Audio: 6-channel (L R C LFE Ls Rs), 24-bit, 48 kHz")
                lines.append("Audio mapping: \(audioQC.mappingDescription)")
                lines.append("Audio peak: \(QCReport.formatPeak(dbfs: audioQC.peakDBFS))")
                lines.append("Loudness: \(LoudnessAdvice.describe(lufs: audioQC.loudnessLUFS))")
                if !audioQC.mappingVerified {
                    lines.append("⚠️ Channel order was not verifiable — listen to a surround check before screening.")
                }
            } else {
                lines.append("Audio: none (MOS)")
            }
            report.add("Composition \(index + 1)", lines)
        }

        var integrity = assetHashes.map { "\($0.name)  SHA-1 \($0.sha1)" }
        integrity.append("Validation: PASSED — \(validation.compositions) composition(s), \(validation.checkedAssets) assets hash-verified, \(validation.frameCount) frames cross-checked")
        report.add("Integrity", integrity)

        // Next to the folder, never inside it (would be a foreign asset).
        let qcURL = folderURL.deletingLastPathComponent()
            .appendingPathComponent("\(folderName)_QC.txt")
        return report.write(to: qcURL)
    }

    // MARK: - Picture

    private func encodePicture(source: ProbedSource, editRate: EditRate, to pictureURL: URL, assetUUID: UUID,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let container = settings.container
        // Natural (PAR-corrected) size decides the framing; vImage stretches
        // the coded-size decoded buffers into it, flattening any anamorphic PAR.
        let geometry = FramingGeometry.fit(sourceWidth: source.naturalWidth,
                                           sourceHeight: source.naturalHeight,
                                           in: container)
        let encoder = J2KEncoder(width: container.width, height: container.height,
                                 bitsPerSecond: settings.j2kBitsPerSecond, frameRate: editRate.fps)
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
                                                      firstFrame: ready,
                                                      editRate: (editRate.numerator, editRate.denominator))
                        }
                        try writer?.write(frame: ready)
                        framesWritten += 1

                        if framesWritten % 24 == 0 {
                            onProgress(min(1.0, Double(framesWritten) / Double(estimatedFrames)))
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

    private func writeAudio(source: ProbedSource, editRate: EditRate, to soundURL: URL, assetUUID: UUID,
                            frameCount: Int, needsPullUp: Bool) throws -> AudioQC {
        let conformer = try AudioConformer(source: source, editRate: editRate, needsPullUp: needsPullUp)
        let writer = try PCMMXFWriter(url: soundURL, assetUUID: assetUUID,
                                      channelCount: AudioConformer.channelCount,
                                      sampleRate: AudioConformer.sampleRate,
                                      editRate: (editRate.numerator, editRate.denominator))
        guard writer.bytesPerFrame == conformer.bytesPerFrame else {
            throw ExportError.packagingFailed(
                "audio frame size mismatch: asdcplib expects \(writer.bytesPerFrame), producing \(conformer.bytesPerFrame)")
        }
        for frameIndex in 0..<frameCount {
            if frameIndex % 240 == 0 {
                try Task.checkCancellation()
            }
            try writer.write(frame: try conformer.nextFrame())
        }
        try writer.finish()
        return AudioQC(peakDBFS: conformer.peakDBFS,
                       loudnessLUFS: conformer.integratedLUFS,
                       mappingDescription: conformer.channelMappingDescription,
                       mappingVerified: conformer.channelMappingVerified)
    }

    // MARK: - Helpers

    private static func makeFolderURL(firstSource: ProbedSource, firstTitle: String,
                                      settings: DCPSettings) -> URL {
        let fps = EditRate.forSource(frameRate: firstSource.frameRate)?.rate.fps ?? 24
        let estimatedFrames = max(1, Int((firstSource.duration * Double(fps)).rounded()))
        let name = DCPPackage.folderName(contentTitle: firstTitle,
                                         container: settings.container,
                                         frameCount: estimatedFrames,
                                         hasAudio: firstSource.hasAudio,
                                         options: settings.dcnc)
        let parent = firstSource.url.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name)_\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private static func removeAppleDoubleFiles(in folderURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("._") {
            try? FileManager.default.removeItem(at: url)
        }
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
