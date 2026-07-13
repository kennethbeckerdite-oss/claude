import Foundation

/// Rec.709 video RGB → 12-bit DCI X'Y'Z' (SMPTE ST 428-1).
///
/// Pipeline per component: 16-bit code → linear (display gamma 2.4 per
/// BT.1886, the standard assumption for video masters) → CIE XYZ via the
/// Rec.709/D65 matrix → scale luminance to the 48 cd/m² DCI reference
/// (× 48/52.37) → X'Y'Z' encode with 1/2.6 gamma → 12-bit integer.
public final class ColorTransform: Sendable {
    /// DCDM normalization constant from SMPTE RP 431-2: peak white 48 cd/m²
    /// against the 52.37 cd/m² encoding reference.
    public static let dciLuminanceScale = 48.0 / 52.37

    /// Rec.709 → XYZ (D65), linear light, row-major.
    public static let rec709ToXYZ: [Double] = [
        0.4123908, 0.3575843, 0.1804808,
        0.2126390, 0.7151687, 0.0721923,
        0.0193308, 0.1191948, 0.9505322,
    ]

    private let decodeLUT: [Float]
    private let matrix: [Float]

    public init(sourceGamma: Double = 2.4) {
        var lut = [Float](repeating: 0, count: 65536)
        for code in 0..<65536 {
            lut[code] = Float(pow(Double(code) / 65535.0, sourceGamma))
        }
        decodeLUT = lut
        matrix = Self.rec709ToXYZ.map { Float($0 * Self.dciLuminanceScale) }
    }

    /// Transforms one pixel; the slow, obviously-correct path used by tests
    /// and as the reference for `convert`.
    public func convertPixel(r: UInt16, g: UInt16, b: UInt16) -> (x: UInt16, y: UInt16, z: UInt16) {
        let lr = decodeLUT[Int(r)]
        let lg = decodeLUT[Int(g)]
        let lb = decodeLUT[Int(b)]
        let x = matrix[0] * lr + matrix[1] * lg + matrix[2] * lb
        let y = matrix[3] * lr + matrix[4] * lg + matrix[5] * lb
        let z = matrix[6] * lr + matrix[7] * lg + matrix[8] * lb
        return (Self.encode(x), Self.encode(y), Self.encode(z))
    }

    /// Interleaved 16-bit RGBA (host-endian, e.g. kCVPixelFormatType_64RGBALE)
    /// → three 12-bit planes. Source rows are read honoring `rowBytes`;
    /// output lands inside planes of `planeWidth` columns at
    /// (`xOffset`, `yOffset`), so a letterboxed container can be written
    /// directly (untouched plane areas stay black).
    public func convert(rgba: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int,
                        xPlane: UnsafeMutablePointer<UInt16>,
                        yPlane: UnsafeMutablePointer<UInt16>,
                        zPlane: UnsafeMutablePointer<UInt16>,
                        planeWidth: Int, xOffset: Int = 0, yOffset: Int = 0) {
        decodeLUT.withUnsafeBufferPointer { lut in
            for row in 0..<height {
                let rowPtr = (rgba + row * rowBytes).assumingMemoryBound(to: UInt16.self)
                var outIndex = (yOffset + row) * planeWidth + xOffset
                for column in 0..<width {
                    let pixel = rowPtr + column * 4
                    let lr = lut[Int(pixel[0])]
                    let lg = lut[Int(pixel[1])]
                    let lb = lut[Int(pixel[2])]
                    let x = matrix[0] * lr + matrix[1] * lg + matrix[2] * lb
                    let y = matrix[3] * lr + matrix[4] * lg + matrix[5] * lb
                    let z = matrix[6] * lr + matrix[7] * lg + matrix[8] * lb
                    xPlane[outIndex] = Self.encode(x)
                    yPlane[outIndex] = Self.encode(y)
                    zPlane[outIndex] = Self.encode(z)
                    outIndex += 1
                }
            }
        }
    }

    /// Linear (already DCI-scaled) → 12-bit X'Y'Z' code value.
    @inline(__always)
    static func encode(_ linear: Float) -> UInt16 {
        if linear <= 0 { return 0 }
        let encoded = powf(linear, 1.0 / 2.6) * 4095.0
        if encoded >= 4095 { return 4095 }
        return UInt16(encoded.rounded())
    }
}
