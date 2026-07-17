import SwiftUI
import TranscodeKit
import UniformTypeIdentifiers

/// Advanced MP4 controls for one film card. Binds to that card's config only.
struct MP4SettingsView: View {
    let source: ProbedSource
    @Binding var config: AppState.MP4JobConfig

    @State private var showingSubtitlePicker = false

    private static let presets: [Double] = [2, 3, 4]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video file (MP4)")
                .font(.headline)

            Picker("Mode", selection: $config.mode) {
                ForEach(AppState.MP4Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch config.mode {
            case .smallHQ:
                Text(smallHQSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .festivalShort:
                Text(festivalShortSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .targetSize:
                targetSizeControls
            }

            subtitleRow
        }
        .fileImporter(isPresented: $showingSubtitlePicker,
                      allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText, .plainText, .text]) { result in
            if case .success(let url) = result {
                config.subtitleURL = url
            }
        }
    }

    private var targetSizeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Target size") {
                HStack {
                    ForEach(Self.presets, id: \.self) { preset in
                        Toggle("\(Int(preset)) GB",
                               isOn: Binding(
                                get: { config.targetGigabytes == preset },
                                set: { if $0 { config.targetGigabytes = preset } }))
                        .toggleStyle(.button)
                    }
                    TextField("Custom", value: $config.targetGigabytes,
                              format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("GB")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Codec", selection: $config.codec) {
                ForEach(MP4Settings.Codec.allCases, id: \.self) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            Text(bitrateSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var subtitleRow: some View {
        HStack {
            if let subtitleURL = config.subtitleURL {
                Image(systemName: "captions.bubble.fill").foregroundStyle(.secondary)
                Text(subtitleURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    config.subtitleURL = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            } else {
                Button("Burn subtitles… (.srt)") { showingSubtitlePicker = true }
                Text("Optional — captions are drawn into the picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var smallHQSummary: String {
        let estimatedBytes = BitrateCalculator.estimatedOutputBytes(
            videoBitsPerSecond: 6_000_000,
            durationSeconds: source.duration,
            audioBitsPerSecond: source.hasAudio ? 160_000 : 0,
            safetyFactor: 1.0)
        let size = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
        return "H.264 High · 6 Mb/s · up to 1920×1080 (no upscaling) · AAC 160 kb/s stereo — about \(size) for this film."
    }

    private var festivalShortSummary: String {
        let bitrate = BitrateCalculator.videoBitsPerSecond(
            targetBytes: 1_900_000_000,
            durationSeconds: source.duration,
            audioBitsPerSecond: source.hasAudio ? 160_000 : 0)
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "Festival submission spec: lands under 2 GB (≈ %.1f Mb/s video) · H.264 for screener compatibility · up to 1920×1080 · AAC 160 kb/s stereo.", mbps)
    }

    private var bitrateSummary: String {
        let bitrate = BitrateCalculator.videoBitsPerSecond(
            targetBytes: Int64(config.targetGigabytes * 1_000_000_000),
            durationSeconds: source.duration,
            audioBitsPerSecond: source.hasAudio ? 256_000 : 0)
        let mbps = Double(bitrate) / 1_000_000
        var summary = String(format: "≈ %.1f Mb/s video", mbps)
        if source.hasAudio {
            summary += " + 256 kb/s stereo AAC"
        }
        if mbps < 3 {
            summary += " — low for this duration; consider a larger target"
        }
        return summary
    }
}
