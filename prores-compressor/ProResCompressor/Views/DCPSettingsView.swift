import DCPKit
import SwiftUI
import TranscodeKit
import UniformTypeIdentifiers

/// Advanced cinema-package controls for one film card. Binds to that card's
/// config only; the simple path (title + auto everything) lives on the card.
struct DCPSettingsView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource
    @Binding var config: AppState.DCPJobConfig
    let itemID: AppState.QueueItem.ID

    @State private var showingElementPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cinema package (DCP)")
                .font(.headline)

            Picker("Screen shape", selection: $config.container) {
                ForEach(DCPContainer.allCases, id: \.self) { container in
                    Text(container.displayName).tag(container)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            LabeledContent("Picture quality") {
                HStack {
                    Slider(value: $config.bitrateMbps, in: 75...250, step: 25)
                        .frame(width: 200)
                    Text("\(Int(config.bitrateMbps)) Mb/s")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
            }

            Picker("Source gamma", selection: $config.sourceGamma) {
                Text("2.4 — standard for graded masters (default)").tag(2.4)
                Text("2.2 — web-style/ungraded masters").tag(2.2)
                Text("2.6 — cinema-graded masters").tag(2.6)
            }
            .help("How your film's brightness was mastered. If the DCP looks too dark or washed out next to your master, try the other setting.")

            Picker("Kind", selection: $config.dcnc.kind) {
                ForEach(DCNCOptions.Kind.allCases, id: \.self) { kind in
                    Text(kind == .auto ? "Auto (by duration)" : kind.rawValue).tag(kind)
                }
            }

            LabeledContent("Language / Subs / Facility") {
                HStack {
                    TextField("XX", text: $config.dcnc.audioLanguage)
                        .frame(width: 44)
                    TextField("XX", text: $config.dcnc.subtitleLanguage)
                        .frame(width: 44)
                    TextField("PRC", text: $config.dcnc.facility)
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

            additionalVideos

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $showingElementPicker,
                      allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie]) { result in
            if case .success(let url) = result {
                appState.addDCPElement(to: itemID, url: url)
            }
        }
    }

    @ViewBuilder
    private var additionalVideos: some View {
        HStack {
            Text(config.extraElements.isEmpty
                 ? "One film in this package"
                 : "\(config.extraElements.count + 1) films in this package — each gets its own title on the cinema server")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Add another video…") { showingElementPicker = true }
                .font(.caption)
        }

        if !config.extraElements.isEmpty {
            ForEach(Array(config.extraElements.enumerated()), id: \.element.id) { index, element in
                HStack {
                    Text("\(index + 2).")
                        .foregroundStyle(.secondary)
                    TextField("Title", text: Binding(
                        get: { element.title },
                        set: { config.extraElements[index].title = $0 }))
                    if !EditRate.isSupported(frameRate: element.source.frameRate) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("\(String(format: "%.3f", element.source.frameRate)) fps — cinemas need 24, 25, or 30")
                    }
                    Button {
                        config.extraElements.remove(at: index)
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
            contentTitle: config.title.isEmpty
                ? source.url.deletingPathExtension().lastPathComponent : config.title,
            container: config.container,
            frameCount: max(1, Int((source.duration * Double(fps)).rounded())),
            hasAudio: source.hasAudio,
            options: config.dcnc)
    }

    private var summary: String {
        let mapping = EditRate.forSource(frameRate: source.frameRate)
        let fps = mapping?.rate.fps ?? 24
        var text = "Made to the cinema standard (SMPTE 2K, \(fps) fps, surround-ready sound)."
        if mapping?.needsPullUp == true {
            text += " Your film's frame rate will be gently conformed (0.1% — nobody will notice)."
        }
        let suggestion = DCPContainer.suggested(width: source.displayWidth, height: source.displayHeight)
        if suggestion != config.container {
            text += " Heads-up: this film's shape suggests \(suggestion.displayName)."
        }
        return text
    }
}
