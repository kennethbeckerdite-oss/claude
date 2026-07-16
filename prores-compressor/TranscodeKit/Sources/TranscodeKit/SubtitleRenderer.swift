import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Renders a subtitle cue to a full-frame transparent CGImage (white text,
/// black outline, bottom-centered, word-wrapped) using CoreText. The rendered
/// image is cached per (text, size) since a cue spans many frames.
public final class SubtitleRenderer {
    private var cachedText: String?
    private var cachedWidth = 0
    private var cachedHeight = 0
    private var cachedImage: CGImage?

    public init() {}

    public func image(for text: String, frameWidth: Int, frameHeight: Int) -> CGImage? {
        if text == cachedText, frameWidth == cachedWidth, frameHeight == cachedHeight {
            return cachedImage
        }
        let image = Self.render(text: text, frameWidth: frameWidth, frameHeight: frameHeight)
        cachedText = text
        cachedWidth = frameWidth
        cachedHeight = frameHeight
        cachedImage = image
        return image
    }

    private static func render(text: String, frameWidth: Int, frameHeight: Int) -> CGImage? {
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: frameWidth, height: frameHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let height = CGFloat(frameHeight)
        let width = CGFloat(frameWidth)
        let fontSize = max(16.0, height / 20.0)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeMutablePointer(to: &alignment) { alignmentPtr in
            var settings = [CTParagraphStyleSetting(
                spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentPtr)]
            return CTParagraphStyleCreate(&settings, settings.count)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            NSAttributedString.Key(kCTStrokeColorAttributeName as String):
                CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            // Negative width = stroke AND fill (outlined text).
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -fontSize * 0.14,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let maxTextWidth = width * 0.9
        let constraint = CGSize(width: maxTextWidth, height: height * 0.4)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)

        // CoreText draws upright in this bottom-left context; low y = image
        // bottom, so a small bottom margin puts the caption near the frame's
        // lower edge once the image is composited over the video.
        let bottomMargin = height * 0.06
        let boxWidth = min(maxTextWidth, ceil(textSize.width) + 4)
        let boxHeight = ceil(textSize.height) + 4
        let rect = CGRect(x: (width - boxWidth) / 2, y: bottomMargin, width: boxWidth, height: boxHeight)

        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}

/// Burns subtitle cues into decoded BGRA video frames. One instance per export;
/// `draw` is called per frame in presentation order.
public final class SubtitleBurner {
    private let track: SubtitleTrack
    private let renderer = SubtitleRenderer()
    private var cursor = 0

    public init(cues: [SubtitleCue]) {
        track = SubtitleTrack(cues: cues)
    }

    public var isEmpty: Bool { track.cues.isEmpty }
    public var cueCount: Int { track.cues.count }

    /// Composites the active cue (if any) into the pixel buffer in place.
    /// The buffer must be BGRA (`kCVPixelFormatType_32BGRA`).
    public func draw(into pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        guard let cue = track.cue(at: time, cursor: &cursor) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let cueImage = renderer.image(for: cue.text, frameWidth: width, frameHeight: height) else {
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA little-endian = premultiplied-first byte order 32 little.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace, bitmapInfo: bitmapInfo) else { return }

        // Flip to a top-left origin so the CGImage composites upright over the
        // video (whose row 0 is the top of the frame).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cueImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }
}
