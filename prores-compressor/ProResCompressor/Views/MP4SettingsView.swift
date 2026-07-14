import SwiftUI
import TranscodeKit

struct MP4SettingsView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource

    private static let presets: [Double] = [2, 3, 4]

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $appState.mp4Mode) {
                ForEach(AppState.MP4Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch appState.mp4Mode {
            case .smallHQ:
                Text(smallHQSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .targetSize:
                targetSizeControls
            }
        }
    }

    private var targetSizeControls: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Target size") {
                HStack {
                    ForEach(Self.presets, id: \.self) { preset in
                        Toggle("\(Int(preset)) GB",
                               isOn: Binding(
                                get: { appState.targetGigabytes == preset },
                                set: { if $0 { appState.targetGigabytes = preset } }))
                        .toggleStyle(.button)
                    }
                    TextField("Custom", value: $appState.targetGigabytes,
                              format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("GB")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Codec", selection: $appState.mp4Codec) {
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

    private var smallHQSummary: String {
        let estimatedBytes = BitrateCalculator.estimatedOutputBytes(
            videoBitsPerSecond: 6_000_000,
            durationSeconds: source.duration,
            audioBitsPerSecond: source.hasAudio ? 160_000 : 0,
            safetyFactor: 1.0)
        let size = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
        return "H.264 High · 6 Mb/s · up to 1920×1080 (no upscaling) · AAC 160 kb/s stereo — about \(size) for this file. Ported from the HandBrake \"MP4 Small & HQ\" preset."
    }

    private var bitrateSummary: String {
        let bitrate = BitrateCalculator.videoBitsPerSecond(
            targetBytes: Int64(appState.targetGigabytes * 1_000_000_000),
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
