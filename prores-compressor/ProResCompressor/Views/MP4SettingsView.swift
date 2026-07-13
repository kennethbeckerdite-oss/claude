import SwiftUI
import TranscodeKit

struct MP4SettingsView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource

    private static let presets: [Double] = [2, 3, 4]

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
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
