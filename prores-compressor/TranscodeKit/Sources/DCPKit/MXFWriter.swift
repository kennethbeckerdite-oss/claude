import CASDCP
import Foundation
import TranscodeKit

private let errorBufferLength = 256

private func withWriterConfig<T>(assetUUID: UUID, _ body: (UnsafePointer<asdcp_writer_config>) -> T) -> T {
    var config = asdcp_writer_config()
    withUnsafeMutableBytes(of: &config.asset_uuid) { destination in
        withUnsafeBytes(of: assetUUID.uuid) { source in
            destination.copyMemory(from: source)
        }
    }
    return "ProRes Compressor".withCString { product in
        "kennethbeckerdite".withCString { company in
            "0.1.0".withCString { version in
                config.company_name = company
                config.product_name = product
                config.product_version = version
                return withUnsafePointer(to: config, body)
            }
        }
    }
}

private func shimError(_ buffer: [CChar]) -> String {
    String(cString: buffer, encoding: .utf8) ?? "unknown asdcplib error"
}

/// JPEG 2000 picture track file (SMPTE ST 429-4).
public final class J2KMXFWriter {
    private var handle: OpaquePointer?

    /// `firstFrame` supplies the picture descriptor only; write it again
    /// with `write(frame:)`.
    public init(url: URL, assetUUID: UUID, firstFrame: Data,
                editRate: (numerator: Int, denominator: Int) = (24, 1)) throws {
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        handle = firstFrame.withUnsafeBytes { frame in
            withWriterConfig(assetUUID: assetUUID) { config in
                asdcp_j2k_writer_open(url.path, config,
                                      frame.bindMemory(to: UInt8.self).baseAddress,
                                      frame.count,
                                      UInt32(editRate.numerator), UInt32(editRate.denominator),
                                      &errorBuffer, errorBufferLength)
            }
        }
        guard handle != nil else {
            throw ExportError.packagingFailed("picture MXF open: \(shimError(errorBuffer))")
        }
    }

    public func write(frame: Data) throws {
        guard let handle else {
            throw ExportError.packagingFailed("picture MXF writer already closed")
        }
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        let status = frame.withUnsafeBytes { bytes in
            asdcp_j2k_write_frame(handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                                  bytes.count, &errorBuffer, errorBufferLength)
        }
        guard status == 0 else {
            throw ExportError.packagingFailed("picture MXF write: \(shimError(errorBuffer))")
        }
    }

    public func finish() throws {
        guard let handle else { return }
        self.handle = nil
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        guard asdcp_j2k_writer_finish(handle, &errorBuffer, errorBufferLength) == 0 else {
            throw ExportError.packagingFailed("picture MXF finalize: \(shimError(errorBuffer))")
        }
    }

    deinit {
        if let handle {
            asdcp_j2k_writer_abort(handle)
        }
    }
}

/// PCM audio track file (SMPTE ST 429-3), 24-bit interleaved.
public final class PCMMXFWriter {
    private var handle: OpaquePointer?
    public let bytesPerFrame: Int

    public init(url: URL, assetUUID: UUID, channelCount: Int, sampleRate: Int,
                editRate: (numerator: Int, denominator: Int) = (24, 1)) throws {
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        handle = withWriterConfig(assetUUID: assetUUID) { config in
            asdcp_pcm_writer_open(url.path, config,
                                  UInt32(channelCount), UInt32(sampleRate),
                                  UInt32(editRate.numerator), UInt32(editRate.denominator),
                                  &errorBuffer, errorBufferLength)
        }
        guard let handle else {
            throw ExportError.packagingFailed("audio MXF open: \(shimError(errorBuffer))")
        }
        bytesPerFrame = Int(asdcp_pcm_frame_buffer_size(handle))
    }

    public func write(frame: Data) throws {
        guard let handle else {
            throw ExportError.packagingFailed("audio MXF writer already closed")
        }
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        let status = frame.withUnsafeBytes { bytes in
            asdcp_pcm_write_frame(handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                                  bytes.count, &errorBuffer, errorBufferLength)
        }
        guard status == 0 else {
            throw ExportError.packagingFailed("audio MXF write: \(shimError(errorBuffer))")
        }
    }

    public func finish() throws {
        guard let handle else { return }
        self.handle = nil
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        guard asdcp_pcm_writer_finish(handle, &errorBuffer, errorBufferLength) == 0 else {
            throw ExportError.packagingFailed("audio MXF finalize: \(shimError(errorBuffer))")
        }
    }

    deinit {
        if let handle {
            asdcp_pcm_writer_abort(handle)
        }
    }
}

/// Read-back structs for validation.
public struct J2KTrackInfo {
    public let frameCount: Int
    public let storedWidth: Int
    public let storedHeight: Int
    public let editRate: (numerator: Int, denominator: Int)
    public let assetUUID: UUID

    public static func read(url: URL) throws -> J2KTrackInfo {
        var info = asdcp_j2k_info()
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        guard asdcp_read_j2k_info(url.path, &info, &errorBuffer, errorBufferLength) == 0 else {
            throw ExportError.validationFailed("picture MXF read: \(shimError(errorBuffer))")
        }
        return J2KTrackInfo(
            frameCount: Int(info.frame_count),
            storedWidth: Int(info.stored_width),
            storedHeight: Int(info.stored_height),
            editRate: (Int(info.edit_rate_num), Int(info.edit_rate_den)),
            assetUUID: UUID(uuid: info.asset_uuid))
    }
}

public struct PCMTrackInfo {
    public let frameCount: Int
    public let channelCount: Int
    public let quantizationBits: Int
    public let sampleRate: Int
    public let assetUUID: UUID

    public static func read(url: URL) throws -> PCMTrackInfo {
        var info = asdcp_pcm_info()
        var errorBuffer = [CChar](repeating: 0, count: errorBufferLength)
        guard asdcp_read_pcm_info(url.path, &info, &errorBuffer, errorBufferLength) == 0 else {
            throw ExportError.validationFailed("audio MXF read: \(shimError(errorBuffer))")
        }
        let denominator = max(1, Int(info.sample_rate_den))
        return PCMTrackInfo(
            frameCount: Int(info.frame_count),
            channelCount: Int(info.channel_count),
            quantizationBits: Int(info.quantization_bits),
            sampleRate: Int(info.sample_rate_num) / denominator,
            assetUUID: UUID(uuid: info.asset_uuid))
    }
}
