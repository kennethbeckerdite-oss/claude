import AppKit
import SwiftUI
import TranscodeKit

struct DoneView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource
    let result: ExportResult

    @State private var isZipping = false
    @State private var zipURL: URL?
    @State private var zipFailed = false

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
                if let qcReportURL = result.qcReportURL {
                    Button("QC Report") {
                        NSWorkspace.shared.open(qcReportURL)
                    }
                }
                if isDCP {
                    zipButton
                }
            }

            HStack {
                Button("Export Another Setting") { appState.backToSettings() }
                Button("New File") { appState.reset() }
                    .keyboardShortcut(.defaultAction)
            }

            if zipFailed {
                Text("Zip failed — check free disk space.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var zipButton: some View {
        if let zipURL {
            Button("Reveal Zip") {
                NSWorkspace.shared.activateFileViewerSelecting([zipURL])
            }
        } else if isZipping {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Zipping…")
            }
        } else {
            Button("Zip for Upload") { zipForUpload() }
        }
    }

    /// ditto -k keeps the archive AppleDouble-free (`--norsrc --noqtn`) —
    /// exactly what festivals taking DCP uploads need.
    private func zipForUpload() {
        isZipping = true
        zipFailed = false
        let folder = result.outputURL
        let destination = folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent + ".zip")
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--norsrc", "--noqtn", folder.path, destination.path]
            var succeeded = false
            do {
                try process.run()
                process.waitUntilExit()
                succeeded = process.terminationStatus == 0
            } catch {
                succeeded = false
            }
            let ok = succeeded
            await MainActor.run {
                isZipping = false
                if ok {
                    zipURL = destination
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } else {
                    zipFailed = true
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }
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
