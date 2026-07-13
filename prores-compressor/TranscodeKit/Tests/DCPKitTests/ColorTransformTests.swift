import XCTest
@testable import DCPKit

final class ColorTransformTests: XCTestCase {
    let transform = ColorTransform()

    /// Reference white: Rec.709 (1,1,1) → D65 XYZ (0.9505, 1.0, 1.0891),
    /// scaled by 48/52.37 and 2.6-gamma encoded. Y' = 3960 is the canonical
    /// DCI-white luminance code value (matches DCP-o-matic/libdcp output).
    func testReferenceWhite() {
        let (x, y, z) = transform.convertPixel(r: 65535, g: 65535, b: 65535)
        XCTAssertEqual(Int(y), 3960, accuracy: 1)
        XCTAssertEqual(Int(x), 3883, accuracy: 1)
        XCTAssertEqual(Int(z), 4092, accuracy: 1)
    }

    func testBlackIsZero() {
        let (x, y, z) = transform.convertPixel(r: 0, g: 0, b: 0)
        XCTAssertEqual(x, 0)
        XCTAssertEqual(y, 0)
        XCTAssertEqual(z, 0)
    }

    /// 18% grey: code 0.462 (≈ 18% linear through gamma 2.4).
    /// Grey must stay neutral: X'/Y'/Z' in the same ratios as white.
    func testMidGreyStaysNeutral() {
        let code = UInt16(0.462 * 65535)
        let (x, y, z) = transform.convertPixel(r: code, g: code, b: code)
        // Same chromaticity as white → same X:Y:Z ratio after encoding.
        let xOverY = Double(x) / Double(y)
        let zOverY = Double(z) / Double(y)
        XCTAssertEqual(xOverY, 3883.0 / 3960.0, accuracy: 0.002)
        XCTAssertEqual(zOverY, 4092.0 / 3960.0, accuracy: 0.002)
    }

    /// Pure Rec.709 primaries produce XYZ in the matrix's column ratios.
    func testPureRedMatchesMatrix() {
        let (x, y, z) = transform.convertPixel(r: 65535, g: 0, b: 0)
        let expected = expectedEncode(linearRGB: (1, 0, 0))
        XCTAssertEqual(Int(x), Int(expected.0), accuracy: 1)
        XCTAssertEqual(Int(y), Int(expected.1), accuracy: 1)
        XCTAssertEqual(Int(z), Int(expected.2), accuracy: 1)
    }

    func testMonotonicInLuminance() {
        var previous = -1
        for code in stride(from: 0, through: 65535, by: 1024) {
            let (_, y, _) = transform.convertPixel(r: UInt16(code), g: UInt16(code), b: UInt16(code))
            XCTAssertGreaterThanOrEqual(Int(y), previous)
            previous = Int(y)
        }
    }

    func testConvertBufferMatchesConvertPixel() {
        // 2×2 RGBA16 frame with distinct colors, dense output.
        let pixels: [[UInt16]] = [
            [65535, 0, 0, 65535], [0, 65535, 0, 65535],
            [0, 0, 65535, 65535], [30000, 40000, 50000, 65535],
        ]
        var interleaved: [UInt16] = []
        for pixel in pixels { interleaved.append(contentsOf: pixel) }

        var xPlane = [UInt16](repeating: 9, count: 4)
        var yPlane = [UInt16](repeating: 9, count: 4)
        var zPlane = [UInt16](repeating: 9, count: 4)
        interleaved.withUnsafeBufferPointer { buffer in
            xPlane.withUnsafeMutableBufferPointer { xp in
                yPlane.withUnsafeMutableBufferPointer { yp in
                    zPlane.withUnsafeMutableBufferPointer { zp in
                        transform.convert(rgba: UnsafeRawPointer(buffer.baseAddress!),
                                          width: 2, height: 2, rowBytes: 2 * 8,
                                          xPlane: xp.baseAddress!, yPlane: yp.baseAddress!,
                                          zPlane: zp.baseAddress!, planeWidth: 2)
                    }
                }
            }
        }

        for (index, pixel) in pixels.enumerated() {
            let reference = transform.convertPixel(r: pixel[0], g: pixel[1], b: pixel[2])
            XCTAssertEqual(xPlane[index], reference.x, "pixel \(index) X")
            XCTAssertEqual(yPlane[index], reference.y, "pixel \(index) Y")
            XCTAssertEqual(zPlane[index], reference.z, "pixel \(index) Z")
        }
    }

    func testOffsetWritesInsideContainerOnly() {
        let planeWidth = 8, planeHeight = 4
        var xPlane = [UInt16](repeating: 0, count: planeWidth * planeHeight)
        var yPlane = xPlane, zPlane = xPlane
        // One white pixel written at offset (3, 1).
        let white: [UInt16] = [65535, 65535, 65535, 65535]
        white.withUnsafeBufferPointer { buffer in
            xPlane.withUnsafeMutableBufferPointer { xp in
                yPlane.withUnsafeMutableBufferPointer { yp in
                    zPlane.withUnsafeMutableBufferPointer { zp in
                        transform.convert(rgba: UnsafeRawPointer(buffer.baseAddress!),
                                          width: 1, height: 1, rowBytes: 8,
                                          xPlane: xp.baseAddress!, yPlane: yp.baseAddress!,
                                          zPlane: zp.baseAddress!,
                                          planeWidth: planeWidth, xOffset: 3, yOffset: 1)
                    }
                }
            }
        }
        for index in 0..<(planeWidth * planeHeight) {
            if index == planeWidth + 3 {
                XCTAssertEqual(Int(yPlane[index]), 3960, accuracy: 1)
            } else {
                XCTAssertEqual(yPlane[index], 0, "letterbox pixel \(index) must stay black")
            }
        }
    }

    private func expectedEncode(linearRGB: (Double, Double, Double)) -> (UInt16, UInt16, UInt16) {
        let m = ColorTransform.rec709ToXYZ
        let scale = ColorTransform.dciLuminanceScale
        func encode(_ v: Double) -> UInt16 {
            let clamped = max(0.0, v * scale)
            let coded = pow(clamped, 1 / 2.6) * 4095
            return UInt16(min(4095, max(0, coded.rounded())))
        }
        let (r, g, b) = linearRGB
        return (encode(m[0] * r + m[1] * g + m[2] * b),
                encode(m[3] * r + m[4] * g + m[5] * b),
                encode(m[6] * r + m[7] * g + m[8] * b))
    }
}
