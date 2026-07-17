import DCPKit
import Foundation
import Observation
import TranscodeKit

/// Item-centric state for the festival-first UI: every dropped film is a card
/// in `items` with its own settings, editable until it runs. No global modes,
/// no wizard phases — the window is always droppable and the list is always
/// visible.
@Observable
@MainActor
final class AppState {
    /// The card's one visible question: "What do you need?"
    enum Deliverable: String, CaseIterable, Equatable {
        case festivalMP4
        case cinemaDCP
        case both
    }

    enum MP4Mode: String, CaseIterable, Equatable {
        case targetSize = "Target size"
        case smallHQ = "Small & HQ"
        case festivalShort = "Festival Short"
    }

    struct MP4JobConfig: Equatable {
        var mode: MP4Mode = .festivalShort
        var targetGigabytes: Double = 2.0
        var codec: MP4Settings.Codec = .hevc
        var subtitleURL: URL?
    }

    struct DCPElementItem: Identifiable, Equatable {
        let id = UUID()
        var source: ProbedSource
        var title: String
    }

    struct DCPJobConfig: Equatable {
        var title: String = ""
        var container: DCPContainer = .flat
        var bitrateMbps: Double = 125
        var dcnc = DCNCOptions()
        /// Assumed display gamma of the Rec.709 source (2.4 = mastering-suite
        /// convention; 2.2 = some houses' assumption for web-style masters).
        var sourceGamma: Double = 2.4
        /// Additional videos that become their own compositions in the package.
        var extraElements: [DCPElementItem] = []
    }

    struct QueueItem: Identifiable {
        let id = UUID()
        var source: ProbedSource
        var deliverable: Deliverable = .festivalMP4
        var mp4 = MP4JobConfig()
        var dcp = DCPJobConfig()
        var status: Status = .ready
        var progress: ExportProgress?
        /// Which half of a "both" card is currently running.
        var runningHalf: Deliverable?
        var mp4Result: ExportResult?
        var dcpResult: ExportResult?

        enum Status: Equatable {
            case ready
            case working
            case done
            case failed(String)
        }

        var dcpSupported: Bool {
            let sources = [source] + dcp.extraElements.map(\.source)
            return sources.allSatisfy { EditRate.isSupported(frameRate: $0.frameRate) }
        }
    }

    var items: [QueueItem] = []
    private(set) var isRunning = false
    private(set) var workingID: QueueItem.ID?
    private(set) var probingCount = 0
    var alertMessage: String?

    /// Last-used choices, copied into each newly dropped film (title, container
    /// suggestion, and package extras are always per-film).
    private var defaultDeliverable: Deliverable = .festivalMP4
    private var defaultMP4 = MP4JobConfig()
    private var defaultDCP = DCPJobConfig()

    private var runTask: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?

    // MARK: - Adding films

    func addFiles(_ urls: [URL]) {
        for url in urls {
            addFile(url)
        }
    }

    private func addFile(_ url: URL) {
        probingCount += 1
        Task {
            defer { probingCount -= 1 }
            do {
                let source = try await SourceProbe.probe(url: url)
                var item = QueueItem(source: source)
                item.deliverable = defaultDeliverable
                item.mp4 = defaultMP4
                item.mp4.subtitleURL = nil
                var dcp = defaultDCP
                dcp.title = url.deletingPathExtension().lastPathComponent
                dcp.container = DCPContainer.suggested(width: source.displayWidth,
                                                       height: source.displayHeight)
                dcp.extraElements = []
                item.dcp = dcp
                if !item.dcpSupported, item.deliverable != .festivalMP4 {
                    item.deliverable = .festivalMP4
                }
                items.append(item)
            } catch {
                alertMessage = "Couldn't read “\(url.lastPathComponent)” — it may not be a video file. (\(error.localizedDescription))"
            }
        }
    }

    /// Probes and appends an additional video to one film's cinema package.
    func addDCPElement(to itemID: QueueItem.ID, url: URL) {
        probingCount += 1
        Task {
            defer { probingCount -= 1 }
            do {
                let source = try await SourceProbe.probe(url: url)
                guard let index = indexOf(itemID) else { return }
                items[index].dcp.extraElements.append(DCPElementItem(
                    source: source, title: url.deletingPathExtension().lastPathComponent))
            } catch {
                alertMessage = "Couldn't read “\(url.lastPathComponent)” — it may not be a video file. (\(error.localizedDescription))"
            }
        }
    }

    /// Remembers a card's choices so the next dropped film starts the same way.
    func rememberDefaults(from item: QueueItem) {
        defaultDeliverable = item.deliverable
        defaultMP4 = item.mp4
        var dcp = item.dcp
        dcp.title = ""
        dcp.extraElements = []
        defaultDCP = dcp
    }

    // MARK: - List management

    func remove(id: QueueItem.ID) {
        guard workingID != id else { return }
        items.removeAll { $0.id == id }
    }

    func retry(id: QueueItem.ID) {
        guard let index = indexOf(id) else { return }
        items[index].status = .ready
        items[index].progress = nil
        items[index].runningHalf = nil
    }

    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.status == .done }
    }

    var readyCount: Int {
        items.filter { $0.status == .ready }.count
    }

    // MARK: - Running

    func exportAll() {
        guard !isRunning, readyCount > 0 else { return }
        isRunning = true
        beginSleepPrevention()
        runTask = Task {
            while !Task.isCancelled,
                  let index = items.firstIndex(where: { $0.status == .ready }) {
                await run(itemAt: index)
            }
            workingID = nil
            isRunning = false
            endSleepPrevention()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func run(itemAt index: Int) async {
        let id = items[index].id
        workingID = id
        items[index].status = .working
        items[index].progress = nil

        do {
            let item = items[index]
            // A "both" card runs the MP4 first (fast), then the DCP. Halves
            // that already have a result (e.g. after a retry) are skipped.
            if item.deliverable != .cinemaDCP, item.mp4Result == nil {
                setRunningHalf(id, .festivalMP4)
                let exporter = MP4Exporter(settings: Self.mp4Settings(for: item))
                let result = try await exporter.export(source: item.source) { progress in
                    Task { @MainActor [weak self] in self?.setProgress(id, progress) }
                }
                if let i = indexOf(id) {
                    items[i].mp4Result = result
                    items[i].progress = nil
                }
            }
            try Task.checkCancellation()
            if item.deliverable != .festivalMP4, item.dcpResult == nil {
                setRunningHalf(id, .cinemaDCP)
                let exporter = DCPExporter(settings: Self.dcpSettings(for: item))
                let result = try await exporter.export(source: item.source) { progress in
                    Task { @MainActor [weak self] in self?.setProgress(id, progress) }
                }
                if let i = indexOf(id) {
                    items[i].dcpResult = result
                    items[i].progress = nil
                }
            }
            if let i = indexOf(id) {
                items[i].status = .done
                items[i].runningHalf = nil
                items[i].progress = nil
            }
        } catch is CancellationError {
            resetAfterCancel(id)
        } catch ExportError.cancelled {
            resetAfterCancel(id)
        } catch {
            if let i = indexOf(id) {
                items[i].status = .failed(Self.friendlyMessage(for: error))
                items[i].runningHalf = nil
                items[i].progress = nil
            }
        }
    }

    /// A cancelled card goes back to "Ready" (finished halves are kept), so
    /// hitting Export All again just picks up where it left off.
    private func resetAfterCancel(_ id: QueueItem.ID) {
        guard let index = indexOf(id) else { return }
        items[index].status = .ready
        items[index].runningHalf = nil
        items[index].progress = nil
    }

    private func setRunningHalf(_ id: QueueItem.ID, _ half: Deliverable) {
        guard let index = indexOf(id) else { return }
        items[index].runningHalf = half
        items[index].progress = nil
    }

    private func setProgress(_ id: QueueItem.ID, _ progress: ExportProgress) {
        guard let index = indexOf(id) else { return }
        items[index].progress = progress
    }

    private func indexOf(_ id: QueueItem.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: - Settings mapping (exporters are built the moment a job starts)

    static func mp4Settings(for item: QueueItem) -> MP4Settings {
        var settings: MP4Settings
        switch item.mp4.mode {
        case .targetSize:
            settings = MP4Settings(
                rateControl: .targetSize(bytes: Int64(item.mp4.targetGigabytes * 1_000_000_000)),
                codec: item.mp4.codec)
        case .smallHQ:
            settings = .smallHQ
        case .festivalShort:
            settings = .festivalShort
        }
        settings.subtitleURL = item.mp4.subtitleURL
        return settings
    }

    static func dcpSettings(for item: QueueItem) -> DCPSettings {
        let title = item.dcp.title.isEmpty
            ? item.source.url.deletingPathExtension().lastPathComponent
            : item.dcp.title
        let elements: [DCPElement] = item.dcp.extraElements.isEmpty ? [] :
            [DCPElement(source: item.source, title: title)]
            + item.dcp.extraElements.map { DCPElement(source: $0.source, title: $0.title) }
        return DCPSettings(
            contentTitle: title,
            container: item.dcp.container,
            j2kBitsPerSecond: Int(item.dcp.bitrateMbps * 1_000_000),
            dcnc: item.dcp.dcnc,
            sourceGamma: item.dcp.sourceGamma,
            elements: elements)
    }

    /// Rewrites engine errors into language a filmmaker can act on.
    static func friendlyMessage(for error: Error) -> String {
        guard let exportError = error as? ExportError else {
            return error.localizedDescription
        }
        switch exportError {
        case .unsupportedSource(let reason) where reason.contains("fps"):
            return "Cinemas can only play films at 24, 25, or 30 frames per second. Export your film from your editing app at 24 fps, then try again. (\(reason))"
        case .unsupportedSource(let reason) where reason.contains("rotation"):
            return "This video is rotated, like phone footage — cinema packages can't carry rotation. Export an upright version from your editing app and try again."
        case .unsupportedSource(let reason):
            return "This file can't be used as-is: \(reason)"
        case .noVideoTrack:
            return "This file has no picture in it — it may be audio-only."
        case .validationFailed(let reason):
            return "The finished package didn't pass its safety check, so don't send it out. Try exporting again. (\(reason))"
        case .readerFailed(let reason):
            return "Couldn't read the film all the way through — the file may be damaged. (\(reason))"
        case .writerFailed(let reason), .packagingFailed(let reason):
            return "Couldn't write the export — check that the drive has enough free space. (\(reason))"
        case .encodingFailed(let reason):
            return "The export failed partway through. Try again; if it keeps happening, note this: \(reason)"
        case .cancelled:
            return "Cancelled"
        }
    }

    // MARK: - Sleep prevention

    private func beginSleepPrevention() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Exporting video")
    }

    private func endSleepPrevention() {
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}
