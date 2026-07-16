import Foundation

/// Plain-text quality-control report written next to every export — the
/// answer to a festival's "what are the specs of your file?" and the
/// paper trail when a projection issue needs arguing about.
public struct QCReport {
    public struct Section {
        public let heading: String
        public let lines: [String]

        public init(heading: String, lines: [String]) {
            self.heading = heading
            self.lines = lines
        }
    }

    public var title: String
    public var sections: [Section]

    public init(title: String, sections: [Section] = []) {
        self.title = title
        self.sections = sections
    }

    public mutating func add(_ heading: String, _ lines: [String]) {
        sections.append(Section(heading: heading, lines: lines))
    }

    public func render(generatedAt date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        var text = """
        \(title)
        Generated: \(formatter.string(from: date)) by ProRes Compressor

        """
        for section in sections {
            text += "\n\(section.heading)\n"
            text += String(repeating: "-", count: section.heading.count) + "\n"
            for line in section.lines {
                text += "  \(line)\n"
            }
        }
        return text
    }

    /// Writes the rendered report; returns its URL. Failures are non-fatal
    /// to the export — callers log and continue.
    @discardableResult
    public func write(to url: URL) -> URL? {
        do {
            try render().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Shared section builders

    public static func sourceSection(_ source: ProbedSource) -> Section {
        var lines = [
            "File: \(source.url.lastPathComponent)",
            "Codec: \(source.videoCodecName) (\(source.bitDepth)-bit)",
            "Dimensions: \(source.displayWidth)×\(source.displayHeight) display"
                + (source.naturalWidth != source.width || source.naturalHeight != source.height
                    ? " (anamorphic, \(source.width)×\(source.height) coded)" : ""),
            String(format: "Frame rate: %.3f fps", source.frameRate),
            String(format: "Duration: %.2f s", source.duration),
            "Size: \(ByteCountFormatter.string(fromByteCount: source.fileSizeBytes, countStyle: .file))",
        ]
        if source.hasAudio {
            lines.append("Audio: \(source.audioChannels) ch @ \(Int(source.audioSampleRate)) Hz")
        } else {
            lines.append("Audio: none")
        }
        return Section(heading: "Source", lines: lines)
    }

    public static func formatPeak(dbfs: Double?) -> String {
        guard let dbfs else { return "silent / not measured" }
        var line = String(format: "%.1f dBFS sample peak", dbfs)
        if dbfs > -0.1 {
            line += "  ⚠️ at or above full scale — check for clipping"
        }
        return line
    }
}
