import DCPKit
import SwiftUI
import TranscodeKit

struct DCPSettingsView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            TextField("Content title", text: $appState.dcpContentTitle)

            Picker("Container", selection: $appState.dcpContainer) {
                ForEach(DCPContainer.allCases, id: \.self) { container in
                    Text(container.displayName).tag(container)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            LabeledContent("JPEG 2000 bitrate") {
                HStack {
                    Slider(value: $appState.dcpBitrateMbps, in: 75...250, step: 25)
                        .frame(width: 200)
                    Text("\(Int(appState.dcpBitrateMbps)) Mb/s")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
            }

            Picker("Kind", selection: $appState.dcpDCNC.kind) {
                ForEach(DCNCOptions.Kind.allCases, id: \.self) { kind in
                    Text(kind == .auto ? "Auto (by duration)" : kind.rawValue).tag(kind)
                }
            }

            LabeledContent("Language / Subs / Facility") {
                HStack {
                    TextField("XX", text: $appState.dcpDCNC.audioLanguage)
                        .frame(width: 44)
                    TextField("XX", text: $appState.dcpDCNC.subtitleLanguage)
                        .frame(width: 44)
                    TextField("PRC", text: $appState.dcpDCNC.facility)
                        .frame(width: 60)
                }
                .multilineTextAlignment(.center)
            }

            LabeledContent("Package name") {
                Text(namePreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if !frameRateSupported {
                Label("DCP requires a 24 or 23.976 fps source (this file is \(String(format: "%.3f", source.frameRate)) fps).",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var namePreview: String {
        DCPPackage.folderName(
            contentTitle: appState.dcpContentTitle.isEmpty
                ? source.url.deletingPathExtension().lastPathComponent : appState.dcpContentTitle,
            container: appState.dcpContainer,
            frameCount: max(1, Int((source.duration * 24).rounded())),
            hasAudio: source.hasAudio,
            options: appState.dcpDCNC)
    }

    private var frameRateSupported: Bool {
        abs(source.frameRate - 24.0) < 0.01 || abs(source.frameRate - 23.976) < 0.01
    }

    private var summary: String {
        let mismatch = abs(source.frameRate - 23.976) < 0.01
        let suggestion = DCPContainer.suggested(width: source.displayWidth, height: source.displayHeight)
        var text = "SMPTE 2K 24 fps, unencrypted · 12-bit X'Y'Z' · 5.1-padded 24-bit/48 kHz audio."
        if mismatch {
            text += " 23.976 source will be conformed to 24 fps (0.1% speed-up)."
        }
        if suggestion != appState.dcpContainer {
            text += " Source aspect suggests \(suggestion.displayName)."
        }
        return text
    }
}
