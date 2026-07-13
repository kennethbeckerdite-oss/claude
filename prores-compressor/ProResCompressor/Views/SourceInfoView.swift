import SwiftUI
import TranscodeKit

struct SourceInfoView: View {
    let source: ProbedSource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detailLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var detailLine: String {
        var parts = [
            source.videoCodecName,
            "\(source.width)×\(source.height)",
            String(format: "%.3g fps", source.frameRate),
            Self.durationText(source.duration),
            Self.sizeText(source.fileSizeBytes),
        ]
        if source.hasAudio {
            parts.append("\(source.audioChannels)ch audio")
        } else {
            parts.append("no audio")
        }
        return parts.joined(separator: " · ")
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
