import SwiftUI
import TranscodeKit

struct ExportProgressView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource

    var body: some View {
        VStack(spacing: 16) {
            Text(appState.progress?.phase ?? "Starting…")
                .font(.title3)

            ProgressView(value: appState.progress?.fraction ?? 0)
                .frame(maxWidth: 360)

            HStack(spacing: 4) {
                Text(percentText)
                if let eta = appState.progress?.eta, eta > 1 {
                    Text("· about \(etaText(eta)) left")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Text(source.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Cancel") { appState.cancelExport() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var percentText: String {
        let fraction = appState.progress?.fraction ?? 0
        return String(format: "%.0f%%", fraction * 100)
    }

    private func etaText(_ eta: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = eta >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: eta) ?? "—"
    }
}
