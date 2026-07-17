import SwiftUI
import TranscodeKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var appState = appState
        Group {
            if appState.items.isEmpty {
                EmptyStateView()
            } else {
                VStack(spacing: 12) {
                    DropStripView()
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach($appState.items) { $item in
                                FilmCardView(item: $item)
                            }
                        }
                        .padding(2)
                    }
                    footerBar
                }
                .padding(16)
            }
        }
        // The whole window accepts drops, in every state — even mid-export.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        Label("Drop to add", systemImage: "plus.circle.fill")
                            .font(.title2)
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert("Hmm", isPresented: Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } })) {
            Button("OK") { appState.alertMessage = nil }
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }

    private var footerBar: some View {
        HStack {
            if appState.probingCount > 0 {
                ProgressView().controlSize(.small)
                Text("Reading file…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !appState.isRunning, appState.items.contains(where: { $0.status == .done }) {
                Button("Clear Finished") { appState.clearFinished() }
            }
            Spacer()
            if appState.isRunning {
                Button("Cancel") { appState.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            } else {
                Button {
                    appState.exportAll()
                } label: {
                    Text(appState.readyCount > 1 ? "Export All" : "Export")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(appState.readyCount == 0)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in appState.addFiles([url]) }
                }
            }
        }
        return true
    }
}

/// First-launch screen: says what the app does in one line, in the audience's
/// words, and invites the drop.
struct EmptyStateView: View {
    @Environment(AppState.self) private var appState
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Get your film festival-ready")
                .font(.title)
            Text("Turn your movie file into what festivals ask for:\na small MP4 for uploads, or a cinema package (DCP) for the screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Drop your film anywhere in this window")
                .font(.headline)
                .padding(.top, 8)
            Button("Choose Film…") { showingPicker = true }
                .controlSize(.large)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appState.addFiles(urls)
            }
        }
    }
}

/// Persistent, compact drop target shown above the film list.
struct DropStripView: View {
    @Environment(AppState.self) private var appState
    @State private var showingPicker = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(.secondary)
            Text("Drop another film here — or")
                .foregroundStyle(.secondary)
            Button("Choose Film…") { showingPicker = true }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(Color.secondary.opacity(0.5))
        )
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appState.addFiles(urls)
            }
        }
    }
}
