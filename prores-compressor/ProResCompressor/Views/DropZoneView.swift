import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppState.self) private var appState
    @State private var isTargeted = false
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop a ProRes file here")
                .font(.title2)
            Text("Exports a size-targeted MP4 or a 2K cinema DCP")
                .foregroundStyle(.secondary)
            Button("Choose File…") { showingPicker = true }
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in appState.load(url: url) }
                }
            }
            return true
        }
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie]) { result in
            if case .success(let url) = result {
                appState.load(url: url)
            }
        }
    }
}
