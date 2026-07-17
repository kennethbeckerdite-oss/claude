import AppKit
import DCPKit
import SwiftUI
import TranscodeKit

/// One film = one card: what you dropped, one plain question ("What do you
/// need?"), a title field, and everything else tucked behind Advanced.
struct FilmCardView: View {
    @Environment(AppState.self) private var appState
    @Binding var item: AppState.QueueItem
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch item.status {
            case .ready:
                if isWaitingForItsTurn {
                    statusLine(icon: "clock", tint: .secondary, text: "Waiting for its turn…")
                } else {
                    configuration
                }
            case .working:
                workingStatus
            case .done:
                doneStatus
            case .failed(let message):
                failedStatus(message)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: item.deliverable) { appState.rememberDefaults(from: item) }
        .onChange(of: item.mp4) { appState.rememberDefaults(from: item) }
        .onChange(of: item.dcp) { appState.rememberDefaults(from: item) }
    }

    private var isWaitingForItsTurn: Bool {
        appState.isRunning && appState.workingID != item.id
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.status != .working {
                Button {
                    appState.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from the list")
            }
        }
    }

    private var sourceLine: String {
        var parts = [
            SourceInfoView.durationText(item.source.duration),
            SourceInfoView.sizeText(item.source.fileSizeBytes),
            "\(item.source.displayWidth)×\(item.source.displayHeight)",
        ]
        if !item.source.hasAudio {
            parts.append("no sound")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Configuration (status == .ready)

    @ViewBuilder
    private var configuration: some View {
        Text("What do you need?")
            .font(.callout)
            .foregroundStyle(.secondary)

        deliverableChoice

        if !item.dcpSupported {
            Label("A cinema package needs 24, 25, or 30 frames per second — this film is \(String(format: "%.3g", item.source.frameRate)) fps. You can still make the MP4, or re-export the film at 24 fps first.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if item.deliverable != .festivalMP4 {
            LabeledContent("Film title") {
                TextField("Title shown to the cinema", text: $item.dcp.title)
            }
            .font(.callout)
        }

        DisclosureGroup("Advanced settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                if item.deliverable != .cinemaDCP {
                    MP4SettingsView(source: item.source, config: $item.mp4)
                }
                if item.deliverable != .festivalMP4 {
                    if item.deliverable == .both { Divider() }
                    DCPSettingsView(source: item.source, config: $item.dcp, itemID: item.id)
                }
            }
            .padding(.top, 8)
        }
        .font(.callout)

        statusLine(icon: "checkmark.circle", tint: .secondary, text: "Ready to export")
    }

    private var deliverableChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            choiceRow(.festivalMP4,
                      title: "Festival upload file",
                      detail: "an MP4 under 2 GB — for FilmFreeway and online screeners, plays anywhere",
                      disabled: false)
            choiceRow(.cinemaDCP,
                      title: "Cinema package (DCP)",
                      detail: "the format theaters and festivals project on the big screen",
                      disabled: !item.dcpSupported)
            choiceRow(.both,
                      title: "Both",
                      detail: "one of each, made back to back",
                      disabled: !item.dcpSupported)
        }
    }

    private func choiceRow(_ value: AppState.Deliverable, title: String,
                           detail: String, disabled: Bool) -> some View {
        Button {
            item.deliverable = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.deliverable == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(item.deliverable == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    // MARK: - Working

    @ViewBuilder
    private var workingStatus: some View {
        let label = item.runningHalf == .cinemaDCP
            ? "Making your cinema package… this is the slow one"
            : "Making your festival video file…"
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small)
                Text(label)
                    .font(.callout)
                if let eta = item.progress?.eta, eta > 60 {
                    Text("· about \(etaText(eta)) left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: item.progress?.fraction ?? 0)
        }
    }

    private func etaText(_ eta: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = eta >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        return formatter.string(from: eta) ?? "—"
    }

    // MARK: - Done

    @ViewBuilder
    private var doneStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mp4 = item.mp4Result {
                resultRow(label: "✓ Festival file ready (\(SourceInfoView.sizeText(mp4.outputBytes)))",
                          result: mp4, isDCP: false)
            }
            if let dcp = item.dcpResult {
                resultRow(label: "✓ Cinema package ready & verified (\(SourceInfoView.sizeText(dcp.outputBytes)))",
                          result: dcp, isDCP: true)
            }
        }
    }

    private func resultRow(label: String, result: ExportResult, isDCP: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.green)
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
            }
            .buttonStyle(.borderless)
            if let qc = result.qcReportURL {
                Button("Report") { NSWorkspace.shared.open(qc) }
                    .buttonStyle(.borderless)
                    .help("Spec sheet for this export — festivals sometimes ask for these details")
            }
            if isDCP {
                ZipForUploadButton(folderURL: result.outputURL)
            }
        }
    }

    // MARK: - Failed

    @ViewBuilder
    private func failedStatus(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A "both" card may have finished its MP4 before the DCP failed.
            if let mp4 = item.mp4Result {
                resultRow(label: "✓ Festival file ready (\(SourceInfoView.sizeText(mp4.outputBytes)))",
                          result: mp4, isDCP: false)
            }
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Button("Try Again") { appState.retry(id: item.id) }
        }
    }

    private func statusLine(icon: String, tint: Color, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
    }
}

/// Zips a DCP folder for festival upload portals (AppleDouble-free via ditto).
struct ZipForUploadButton: View {
    let folderURL: URL
    @State private var isZipping = false
    @State private var zipURL: URL?

    var body: some View {
        if let zipURL {
            Button("Show Zip") {
                NSWorkspace.shared.activateFileViewerSelecting([zipURL])
            }
            .buttonStyle(.borderless)
        } else if isZipping {
            ProgressView().controlSize(.small)
        } else {
            Button("Zip for Upload") { zip() }
                .buttonStyle(.borderless)
                .help("Makes a single .zip of the cinema package for festivals that take uploads")
        }
    }

    private func zip() {
        isZipping = true
        let folder = folderURL
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
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }
    }
}
