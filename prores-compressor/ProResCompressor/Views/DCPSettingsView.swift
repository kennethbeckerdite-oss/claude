import DCPKit
import SwiftUI
import TranscodeKit
import UniformTypeIdentifiers

struct DCPSettingsView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource

    @State private var showingElementPicker = false

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

            additionalVideos

            LabeledContent("Package name") {
                Text(namePreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if !frameRateSupported(source.frameRate) {
                Label("DCP supports 24, 25, or 30 fps (this file is \(String(format: "%.3f", source.frameRate)) fps).",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $showingElementPicker,
                      allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie]) { result in
            if case .success(let url) = result {
                appState.addDCPElement(url: url)
            }
        }
    }

    @ViewBuilder
    private var additionalVideos: some View {
        @Bindable var appState = appState
        Divider()
        HStack {
            Text(appState.dcpExtraElements.isEmpty
                 ? "Single composition"
                 : "\(appState.dcpExtraElements.count + 1) compositions (one package)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if appState.isAddingDCPElement {
                ProgressView().controlSize(.small)
            }
            Button("Add video…") { showingElementPicker = true }
                .disabled(appState.isAddingDCPElement)
        }

        if !appState.dcpExtraElements.isEmpty {
            // Primary shown first for context, then the removable extras.
            Text("1. \(appState.dcpContentTitle) — plays first")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(appState.dcpExtraElements.enumerated()), id: \.element.id) { index, element in
                HStack {
                    Text("\(index + 2).")
                        .foregroundStyle(.secondary)
                    TextField("Title", text: Binding(
                        get: { element.title },
                        set: { appState.dcpExtraElements[index].title = $0 }))
                    if !frameRateSupported(element.source.frameRate) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("\(String(format: "%.3f", element.source.frameRate)) fps is not a DCP rate")
                    }
                    Button {
                        appState.removeDCPElement(id: element.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
    }

    private var namePreview: String {
        let fps = EditRate.forSource(frameRate: source.frameRate)?.rate.fps ?? 24
        return DCPPackage.folderName(
            contentTitle: appState.dcpContentTitle.isEmpty
                ? source.url.deletingPathExtension().lastPathComponent : appState.dcpContentTitle,
            container: appState.dcpContainer,
            frameCount: max(1, Int((source.duration * Double(fps)).rounded())),
            hasAudio: source.hasAudio,
            options: appState.dcpDCNC)
    }

    private func frameRateSupported(_ frameRate: Double) -> Bool {
        EditRate.isSupported(frameRate: frameRate)
    }

    private var summary: String {
        let mapping = EditRate.forSource(frameRate: source.frameRate)
        let fps = mapping?.rate.fps ?? 24
        let suggestion = DCPContainer.suggested(width: source.displayWidth, height: source.displayHeight)
        var text = "SMPTE 2K \(fps) fps, unencrypted · 12-bit X'Y'Z' · 5.1-padded 24-bit/48 kHz audio."
        if mapping?.needsPullUp == true {
            text += " Fractional source rate will be conformed with a 0.1% speed-up."
        }
        if suggestion != appState.dcpContainer {
            text += " Source aspect suggests \(suggestion.displayName)."
        }
        if !appState.dcpExtraElements.isEmpty {
            text += " Each video becomes its own title in the package."
        }
        return text
    }
}
