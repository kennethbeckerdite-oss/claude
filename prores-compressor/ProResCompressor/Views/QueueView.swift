import AppKit
import SwiftUI
import TranscodeKit

struct QueueView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Text("\(pendingCount) pending")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.isRunningQueue {
                    Button("Cancel") { appState.cancelExport() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    if hasFinished {
                        Button("Clear Finished") { appState.clearFinishedJobs() }
                    }
                    Button("Run Queue") { appState.runQueue() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pendingCount == 0)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(appState.queue) { job in
                        QueueRow(job: job)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pendingCount: Int {
        appState.queue.filter { $0.status == .pending }.count
    }

    private var hasFinished: Bool {
        appState.queue.contains { job in
            if case .done = job.status { return true }
            if case .failed = job.status { return true }
            return false
        }
    }
}

private struct QueueRow: View {
    @Environment(AppState.self) private var appState
    let job: AppState.QueueJob

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .running = job.status, let progress = job.progress {
                    ProgressView(value: progress.fraction)
                        .controlSize(.small)
                } else if case .failed(let message) = job.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.status {
        case .pending:
            if !appState.isRunningQueue {
                Button {
                    appState.removeQueueJob(id: job.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        case .done:
            if let result = job.result {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                .buttonStyle(.borderless)
                if let qc = result.qcReportURL {
                    Button("QC") { NSWorkspace.shared.open(qc) }
                        .buttonStyle(.borderless)
                }
            }
        default:
            EmptyView()
        }
    }
}
