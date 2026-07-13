import AppKit
import SwiftUI
import TranscodeKit

struct DoneView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource
    let result: ExportResult

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(isDCP ? "Exported & verified" : "Export complete")
                .font(.title2)
            Text(result.outputURL.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(sizeLine)
                .foregroundStyle(.secondary)
                .font(.callout)

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                Button("Export Another Setting") { appState.backToSettings() }
                Button("New File") { appState.reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isDCP: Bool {
        result.outputURL.hasDirectoryPath || result.outputURL.pathExtension.isEmpty
    }

    private var sizeLine: String {
        let out = SourceInfoView.sizeText(result.outputBytes)
        let original = SourceInfoView.sizeText(source.fileSizeBytes)
        return "\(out) (from \(original))"
    }
}
