import Foundation

/// DCI 2K image containers.
public enum DCPContainer: String, CaseIterable, Sendable, Equatable {
    case flat
    case scope

    public var width: Int {
        switch self {
        case .flat: return 1998
        case .scope: return 2048
        }
    }

    public var height: Int {
        switch self {
        case .flat: return 1080
        case .scope: return 858
        }
    }

    public var displayName: String {
        switch self {
        case .flat: return "Flat (1998×1080, 1.85:1)"
        case .scope: return "Scope (2048×858, 2.39:1)"
        }
    }

    /// Wider than ~2.1:1 reads as Scope; everything else fits Flat better.
    public static func suggested(width: Int, height: Int) -> DCPContainer {
        guard width > 0, height > 0 else { return .flat }
        let aspect = Double(width) / Double(height)
        return aspect >= 2.1 ? .scope : .flat
    }
}

/// Where the scaled source lands inside the container (letterbox/pillarbox).
public struct FramingGeometry: Equatable, Sendable {
    public let scaledWidth: Int
    public let scaledHeight: Int
    public let xOffset: Int
    public let yOffset: Int

    /// Aspect-preserving fit, centered. Scaled dimensions are forced even
    /// (some JPEG 2000/MXF tooling dislikes odd active regions).
    public static func fit(sourceWidth: Int, sourceHeight: Int, in container: DCPContainer) -> FramingGeometry {
        precondition(sourceWidth > 0 && sourceHeight > 0, "source dimensions must be positive")
        let scale = min(Double(container.width) / Double(sourceWidth),
                        Double(container.height) / Double(sourceHeight))
        var width = min(container.width, Int((Double(sourceWidth) * scale).rounded()))
        var height = min(container.height, Int((Double(sourceHeight) * scale).rounded()))
        width -= width % 2
        height -= height % 2
        return FramingGeometry(
            scaledWidth: width,
            scaledHeight: height,
            xOffset: (container.width - width) / 2,
            yOffset: (container.height - height) / 2)
    }

    public init(scaledWidth: Int, scaledHeight: Int, xOffset: Int, yOffset: Int) {
        self.scaledWidth = scaledWidth
        self.scaledHeight = scaledHeight
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}
