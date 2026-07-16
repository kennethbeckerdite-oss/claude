import Foundation

/// One subtitle cue with an inclusive-start/exclusive-end time window.
public struct SubtitleCue: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Tolerant SubRip (.srt) parser. Ignores index numbers, accepts `,` or `.`
/// millisecond separators and CRLF/LF/BOM, joins multi-line cues, and strips
/// inline markup (`<i>`, `<b>`, `{\an8}`, …).
public enum SRTParser {
    private static let timecode = try! NSRegularExpression(
        pattern: #"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})"#)

    public static func parse(_ contents: String) -> [SubtitleCue] {
        let normalized = contents
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            guard let times = matchTimecode(lines[index]) else {
                index += 1
                continue
            }
            index += 1
            var textLines: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if matchTimecode(line) != nil { break } // next cue with no blank line
                textLines.append(line)
                index += 1
            }
            let text = cleanMarkup(textLines.joined(separator: "\n"))
            if !text.isEmpty, times.end > times.start {
                cues.append(SubtitleCue(start: times.start, end: times.end, text: text))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    public static func parse(url: URL) throws -> [SubtitleCue] {
        let data = try Data(contentsOf: url)
        // .srt is usually UTF-8; fall back to Latin-1 (common for older files).
        let string = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return parse(string)
    }

    private static func matchTimecode(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = timecode.firstMatch(in: line, range: range) else { return nil }
        func group(_ i: Int) -> Double {
            guard let r = Range(match.range(at: i), in: line) else { return 0 }
            return Double(line[r]) ?? 0
        }
        let start = group(1) * 3600 + group(2) * 60 + group(3) + group(4) / 1000
        let end = group(5) * 3600 + group(6) * 60 + group(7) + group(8) / 1000
        return (start, end)
    }

    private static func cleanMarkup(_ text: String) -> String {
        var result = text
        // Strip HTML/SSA tags.
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        // Decode the handful of entities SRT files use.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
        for (entity, character) in entities {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Finds the active cue for a given time. Cues are assumed sorted by start.
public struct SubtitleTrack: Sendable {
    public let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) {
        self.cues = cues
    }

    /// The cue covering `time`, or nil. Linear scan from a remembered cursor —
    /// playback advances monotonically, so this is effectively O(1) per frame.
    public func cue(at time: TimeInterval, cursor: inout Int) -> SubtitleCue? {
        while cursor < cues.count, cues[cursor].end <= time {
            cursor += 1
        }
        if cursor < cues.count, cues[cursor].start <= time, time < cues[cursor].end {
            return cues[cursor]
        }
        return nil
    }
}
