import COpenJPEG
import Foundation
import TranscodeKit

/// DCI Cinema-2K JPEG 2000 encoder over vendored OpenJPEG.
///
/// Setting `rsiz = OPJ_PROFILE_CINEMA_2K` makes the library enforce the full
/// DCI constraint set internally (CPRL progression, 32×32 code blocks,
/// precincts, tile parts, 9-7 irreversible transform — see
/// `opj_j2k_set_cinema_parameters` in j2k.c); we supply the profile, the
/// rate budget, and the image.
public final class J2KEncoder: Sendable {
    public let width: Int
    public let height: Int
    /// Compressed byte budget for one frame's codestream.
    public let maxFrameBytes: Int
    private let maxComponentBytes: Int

    /// DCI hard ceilings for 2K @ 24 fps (ISO 15444-1 AMD1). The DCI limit is
    /// a *bitrate* (≤250 Mb/s), so the per-frame ceiling scales with fps —
    /// these 24 fps constants are multiplied by 24/fps below.
    private static let dciMaxFrameBytes24 = Int(OPJ_CINEMA_24_CS)
    private static let dciMaxComponentBytes24 = Int(OPJ_CINEMA_24_COMP)

    public init(width: Int, height: Int, bitsPerSecond: Int, frameRate: Int = 24) {
        self.width = width
        self.height = height
        let dciMaxFrameBytes = Self.dciMaxFrameBytes24 * 24 / frameRate
        let dciMaxComponentBytes = Self.dciMaxComponentBytes24 * 24 / frameRate
        let requested = bitsPerSecond / 8 / frameRate
        let frameBytes = min(requested, dciMaxFrameBytes)
        maxFrameBytes = max(frameBytes, 50_000)
        // Keep the per-component cap in the same proportion DCI uses at the ceiling.
        maxComponentBytes = min(dciMaxComponentBytes,
                                Int(Double(maxFrameBytes) * Double(dciMaxComponentBytes)
                                    / Double(dciMaxFrameBytes)))
    }

    /// Encodes one frame from three dense 12-bit X'Y'Z' planes.
    public func encode(xPlane: [UInt16], yPlane: [UInt16], zPlane: [UInt16]) throws -> Data {
        let pixelCount = width * height
        guard xPlane.count == pixelCount, yPlane.count == pixelCount, zPlane.count == pixelCount else {
            throw ExportError.encodingFailed("plane size mismatch")
        }

        var parameters = opj_cparameters_t()
        opj_set_default_encoder_parameters(&parameters)
        parameters.rsiz = OPJ_UINT16(OPJ_PROFILE_CINEMA_2K)
        parameters.max_cs_size = Int32(maxFrameBytes)
        parameters.max_comp_size = Int32(maxComponentBytes)
        parameters.tcp_numlayers = 1
        parameters.cp_disto_alloc = 1
        parameters.irreversible = 1
        let rawBytes = Double(pixelCount * 3 * 12) / 8.0
        parameters.tcp_rates.0 = Float(rawBytes / Double(maxFrameBytes))

        var componentTemplate = opj_image_cmptparm_t()
        componentTemplate.dx = 1
        componentTemplate.dy = 1
        componentTemplate.w = OPJ_UINT32(width)
        componentTemplate.h = OPJ_UINT32(height)
        componentTemplate.x0 = 0
        componentTemplate.y0 = 0
        componentTemplate.prec = 12
        componentTemplate.sgnd = 0
        var componentParams = [componentTemplate, componentTemplate, componentTemplate]

        guard let image = opj_image_create(3, &componentParams, OPJ_CLRSPC_SRGB) else {
            throw ExportError.encodingFailed("opj_image_create failed")
        }
        defer { opj_image_destroy(image) }
        image.pointee.x0 = 0
        image.pointee.y0 = 0
        image.pointee.x1 = OPJ_UINT32(width)
        image.pointee.y1 = OPJ_UINT32(height)

        for (index, plane) in [xPlane, yPlane, zPlane].enumerated() {
            guard let destination = image.pointee.comps[index].data else {
                throw ExportError.encodingFailed("opj image has no component storage")
            }
            plane.withUnsafeBufferPointer { source in
                for i in 0..<pixelCount {
                    destination[i] = Int32(source[i])
                }
            }
        }

        guard let codec = opj_create_compress(OPJ_CODEC_J2K) else {
            throw ExportError.encodingFailed("opj_create_compress failed")
        }
        defer { opj_destroy_codec(codec) }

        let errorBox = ErrorMessageBox()
        let errorContext = Unmanaged.passUnretained(errorBox).toOpaque()
        opj_set_error_handler(codec, { message, context in
            guard let context else { return }
            let box = Unmanaged<ErrorMessageBox>.fromOpaque(context).takeUnretainedValue()
            if let message {
                box.message = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }, errorContext)

        guard opj_setup_encoder(codec, &parameters, image) != 0 else {
            throw ExportError.encodingFailed(errorBox.message ?? "opj_setup_encoder failed")
        }

        let sink = J2KOutputSink()
        guard let stream = opj_stream_default_create(0 /* output */) else {
            throw ExportError.encodingFailed("opj_stream_default_create failed")
        }
        defer { opj_stream_destroy(stream) }

        let sinkContext = Unmanaged.passUnretained(sink).toOpaque()
        opj_stream_set_user_data(stream, sinkContext, { _ in })
        opj_stream_set_write_function(stream) { buffer, count, context in
            // OPJ_SIZE_T imports as Int; -1 is the library's failure sentinel.
            guard let buffer, let context else { return -1 }
            let sink = Unmanaged<J2KOutputSink>.fromOpaque(context).takeUnretainedValue()
            return sink.write(buffer, count: count)
        }
        opj_stream_set_skip_function(stream) { count, context in
            guard let context else { return -1 }
            let sink = Unmanaged<J2KOutputSink>.fromOpaque(context).takeUnretainedValue()
            return sink.skip(count) ? count : -1
        }
        opj_stream_set_seek_function(stream) { position, context in
            guard let context else { return 0 }
            let sink = Unmanaged<J2KOutputSink>.fromOpaque(context).takeUnretainedValue()
            return sink.seek(position) ? 1 : 0
        }

        guard opj_start_compress(codec, image, stream) != 0,
              opj_encode(codec, stream) != 0,
              opj_end_compress(codec, stream) != 0 else {
            throw ExportError.encodingFailed(errorBox.message ?? "JPEG 2000 encode failed")
        }

        return sink.finalData()
    }
}

private final class ErrorMessageBox {
    var message: String?
}

/// Growable, seekable in-memory sink for the OpenJPEG stream callbacks.
/// Seeking backwards is required: the encoder patches TLM markers in the
/// header after encoding the tile data.
private final class J2KOutputSink {
    private var bytes: [UInt8] = []
    private var position = 0

    init() {
        bytes.reserveCapacity(1_400_000)
    }

    func write(_ source: UnsafeRawPointer, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let end = position + count
        if end > bytes.count {
            bytes.append(contentsOf: repeatElement(0, count: end - bytes.count))
        }
        bytes.withUnsafeMutableBufferPointer { destination in
            _ = memcpy(destination.baseAddress! + position, source, count)
        }
        position = end
        return count
    }

    func skip(_ count: Int64) -> Bool {
        seek(Int64(position) + count)
    }

    func seek(_ newPosition: Int64) -> Bool {
        guard newPosition >= 0 else { return false }
        let target = Int(newPosition)
        if target > bytes.count {
            bytes.append(contentsOf: repeatElement(0, count: target - bytes.count))
        }
        position = target
        return true
    }

    func finalData() -> Data {
        Data(bytes)
    }
}
