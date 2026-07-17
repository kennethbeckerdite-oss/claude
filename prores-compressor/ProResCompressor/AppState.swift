import DCPKit
import Foundation
import Observation
import TranscodeKit

@Observable
@MainActor
final class AppState {
    enum Phase {
        case idle
        case probing
        case configuring(ProbedSource)
        case exporting(ProbedSource)
        case done(ProbedSource, ExportResult)
        case failed(ProbedSource?, String)
    }

    enum ExportFormat: String, CaseIterable {
        case mp4 = "MP4"
        case dcp = "DCP"
    }

    private(set) var phase: Phase = .idle
    var progress: ExportProgress?

    enum MP4Mode: String, CaseIterable {
        case targetSize = "Target size"
        case smallHQ = "Small & HQ"
        case festivalShort = "Festival Short"
    }

    // Export configuration (persists across files within a session).
    var format: ExportFormat = .mp4
    var mp4Mode: MP4Mode = .targetSize
    var targetGigabytes: Double = 3.0
    var mp4Codec: MP4Settings.Codec = .hevc
    /// Optional .srt to burn into the MP4 picture.
    var mp4SubtitleURL: URL?
    var dcpContainer: DCPContainer = .flat
    var dcpBitrateMbps: Double = 125
    var dcpContentTitle: String = ""
    var dcpDCNC = DCNCOptions()

    /// Extra videos for a multi-composition DCP (each its own CPL/title). The
    /// primary source in `configuring` is the first composition.
    struct DCPElementItem: Identifiable {
        let id = UUID()
        var source: ProbedSource
        var title: String
    }
    var dcpExtraElements: [DCPElementItem] = []
    var isAddingDCPElement = false

    // MARK: - Batch queue

    struct QueueJob: Identifiable {
        let id = UUID()
        let sourceName: String
        let summary: String
        let exporter: any Exporter
        let primarySource: ProbedSource
        var status: Status = .pending
        var progress: ExportProgress?
        var result: ExportResult?

        enum Status: Equatable {
            case pending, running, done
            case failed(String)
        }
    }

    private(set) var queue: [QueueJob] = []
    private(set) var isRunningQueue = false
    private(set) var runningJobID: QueueJob.ID?

    private var exportTask: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?

    func load(url: URL) {
        guard !isExporting, !isRunningQueue else { return }
        phase = .probing
        // A fresh primary file starts fresh — drop extras and any prior SRT.
        dcpExtraElements = []
        mp4SubtitleURL = nil
        Task {
            do {
                let source = try await SourceProbe.probe(url: url)
                // Follow the loaded file — a stale title from a previous file
                // must never leak into the next export's naming.
                dcpContentTitle = url.deletingPathExtension().lastPathComponent
                phase = .configuring(source)
            } catch {
                phase = .failed(nil, error.localizedDescription)
            }
        }
    }

    /// Probes and appends an additional video to the DCP package.
    func addDCPElement(url: URL) {
        guard !isExporting, !isAddingDCPElement else { return }
        isAddingDCPElement = true
        Task {
            defer { isAddingDCPElement = false }
            do {
                let source = try await SourceProbe.probe(url: url)
                dcpExtraElements.append(DCPElementItem(
                    source: source, title: url.deletingPathExtension().lastPathComponent))
            } catch {
                phase = .failed(nil, error.localizedDescription)
            }
        }
    }

    func removeDCPElement(id: DCPElementItem.ID) {
        dcpExtraElements.removeAll { $0.id == id }
    }

    /// Builds an exporter + display summary from the current settings for the
    /// configured source. Shared by immediate export and the batch queue.
    private func makeMP4Exporter() -> (exporter: any Exporter, summary: String) {
        var settings: MP4Settings
        let modeLabel: String
        switch mp4Mode {
        case .targetSize:
            settings = MP4Settings(
                rateControl: .targetSize(bytes: Int64(targetGigabytes * 1_000_000_000)),
                codec: mp4Codec)
            modeLabel = "\(mp4Codec == .hevc ? "HEVC" : "H.264") · \(String(format: "%.1f", targetGigabytes)) GB"
        case .smallHQ:
            settings = .smallHQ
            modeLabel = "Small & HQ"
        case .festivalShort:
            settings = .festivalShort
            modeLabel = "Festival Short"
        }
        settings.subtitleURL = mp4SubtitleURL
        let subs = mp4SubtitleURL != nil ? " · burned subs" : ""
        return (MP4Exporter(settings: settings), "MP4 · \(modeLabel)\(subs)")
    }

    private func makeDCPExporter(for source: ProbedSource) -> (exporter: any Exporter, summary: String) {
        let primaryTitle = dcpContentTitle.isEmpty
            ? source.url.deletingPathExtension().lastPathComponent : dcpContentTitle
        let elements: [DCPElement] = dcpExtraElements.isEmpty ? [] :
            [DCPElement(source: source, title: primaryTitle)]
            + dcpExtraElements.map { DCPElement(source: $0.source, title: $0.title) }
        let exporter = DCPExporter(settings: DCPSettings(
            contentTitle: primaryTitle,
            container: dcpContainer,
            j2kBitsPerSecond: Int(dcpBitrateMbps * 1_000_000),
            dcnc: dcpDCNC,
            elements: elements))
        let compositions = elements.isEmpty ? 1 : elements.count
        let compLabel = compositions > 1 ? " · \(compositions) comps" : ""
        return (exporter, "DCP · \(dcpContainer == .flat ? "Flat" : "Scope")\(compLabel)")
    }

    private func makeExporter(for source: ProbedSource) -> (exporter: any Exporter, summary: String) {
        switch format {
        case .mp4: return makeMP4Exporter()
        case .dcp: return makeDCPExporter(for: source)
        }
    }

    func startExport() {
        guard case .configuring(let source) = phase, !isRunningQueue else { return }
        let built = makeExporter(for: source)

        progress = nil
        phase = .exporting(source)
        beginSleepPrevention()

        exportTask = Task {
            do {
                let result = try await built.exporter.export(source: source) { progress in
                    Task { @MainActor [weak self] in
                        self?.progress = progress
                    }
                }
                endSleepPrevention()
                phase = .done(source, result)
            } catch is CancellationError {
                endSleepPrevention()
                phase = .configuring(source)
            } catch ExportError.cancelled {
                endSleepPrevention()
                phase = .configuring(source)
            } catch {
                endSleepPrevention()
                phase = .failed(source, error.localizedDescription)
            }
        }
    }

    // MARK: - Queue actions

    /// Adds the current configuration as a queued job, then returns to idle so
    /// the next file can be dropped.
    func addToQueue() {
        guard case .configuring(let source) = phase else { return }
        let built = makeExporter(for: source)
        queue.append(QueueJob(sourceName: source.url.lastPathComponent,
                              summary: built.summary,
                              exporter: built.exporter,
                              primarySource: source))
        phase = .idle
        progress = nil
    }

    /// Queues the festival pairing: a Festival Short MP4 screener plus a DCP,
    /// both from the current master.
    func addScreenerAndDCP() {
        guard case .configuring(let source) = phase else { return }

        var screener = MP4Settings.festivalShort
        screener.subtitleURL = mp4SubtitleURL
        queue.append(QueueJob(sourceName: source.url.lastPathComponent,
                              summary: "MP4 · Festival Short (screener)",
                              exporter: MP4Exporter(settings: screener),
                              primarySource: source))

        let dcp = makeDCPExporter(for: source)
        queue.append(QueueJob(sourceName: source.url.lastPathComponent,
                              summary: dcp.summary,
                              exporter: dcp.exporter,
                              primarySource: source))
        phase = .idle
        progress = nil
    }

    func removeQueueJob(id: QueueJob.ID) {
        guard !isRunningQueue else { return }
        queue.removeAll { $0.id == id && $0.status == .pending }
    }

    func clearFinishedJobs() {
        guard !isRunningQueue else { return }
        queue.removeAll { job in
            if case .pending = job.status { return false }
            if case .running = job.status { return false }
            return true
        }
    }

    /// Runs pending jobs strictly sequentially (exports are resource-hungry).
    func runQueue() {
        guard !isRunningQueue, !isExporting,
              queue.contains(where: { $0.status == .pending }) else { return }
        isRunningQueue = true
        beginSleepPrevention()

        exportTask = Task {
            while let index = queue.firstIndex(where: { $0.status == .pending }) {
                if Task.isCancelled { break }
                let jobID = queue[index].id
                queue[index].status = .running
                queue[index].progress = nil
                runningJobID = jobID

                do {
                    let job = queue[index]
                    let result = try await job.exporter.export(source: job.primarySource) { progress in
                        Task { @MainActor [weak self] in
                            self?.updateJobProgress(id: jobID, progress: progress)
                        }
                    }
                    if let i = queue.firstIndex(where: { $0.id == jobID }) {
                        queue[i].status = .done
                        queue[i].result = result
                        queue[i].progress = nil
                    }
                } catch is CancellationError {
                    setJobFailed(id: jobID, message: "Cancelled")
                    break
                } catch ExportError.cancelled {
                    setJobFailed(id: jobID, message: "Cancelled")
                    break
                } catch {
                    setJobFailed(id: jobID, message: error.localizedDescription)
                }
            }
            runningJobID = nil
            isRunningQueue = false
            endSleepPrevention()
        }
    }

    private func updateJobProgress(id: QueueJob.ID, progress: ExportProgress) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].progress = progress
    }

    private func setJobFailed(id: QueueJob.ID, message: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = .failed(message)
        queue[index].progress = nil
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func reset() {
        guard !isExporting, !isRunningQueue else { return }
        phase = .idle
        progress = nil
    }

    func backToSettings() {
        if case .done(let source, _) = phase {
            phase = .configuring(source)
        } else if case .failed(.some(let source), _) = phase {
            phase = .configuring(source)
        } else {
            phase = .idle
        }
    }

    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

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
