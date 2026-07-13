import SwiftUI
import TranscodeKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.phase {
            case .idle:
                DropZoneView()
            case .probing:
                ProgressView("Reading file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .configuring(let source):
                ConfigureView(source: source)
            case .exporting(let source):
                ExportProgressView(source: source)
            case .done(let source, let result):
                DoneView(source: source, result: result)
            case .failed(let source, let message):
                FailedView(hasSource: source != nil, message: message)
            }
        }
        .padding(24)
        .animation(.default, value: phaseKey)
    }

    private var phaseKey: String {
        switch appState.phase {
        case .idle: return "idle"
        case .probing: return "probing"
        case .configuring: return "configuring"
        case .exporting: return "exporting"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

struct ConfigureView: View {
    @Environment(AppState.self) private var appState
    let source: ProbedSource

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 16) {
            SourceInfoView(source: source)

            Picker("Format", selection: $appState.format) {
                ForEach(AppState.ExportFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch appState.format {
            case .mp4:
                MP4SettingsView(source: source)
            case .dcp:
                DCPSettingsView(source: source)
            }

            Spacer()

            HStack {
                Button("Choose Another File") { appState.reset() }
                Spacer()
                Button("Export") { appState.startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!exportAllowed)
            }
        }
    }

    private var exportAllowed: Bool {
        switch appState.format {
        case .mp4:
            return true
        case .dcp:
            // DCP is 24 fps only; 23.976 is conformed with a 0.1% speed-up.
            return abs(source.frameRate - 24.0) < 0.01 || abs(source.frameRate - 23.976) < 0.01
        }
    }
}

struct FailedView: View {
    @Environment(AppState.self) private var appState
    let hasSource: Bool
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Export Failed")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack {
                Button("Start Over") { appState.reset() }
                if hasSource {
                    Button("Back to Settings") { appState.backToSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
