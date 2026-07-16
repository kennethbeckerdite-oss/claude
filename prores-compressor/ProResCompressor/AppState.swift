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

    private var exportTask: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?

    func load(url: URL) {
        guard !isExporting else { return }
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

    func startExport() {
        guard case .configuring(let source) = phase else { return }

        let exporter: any Exporter
        switch format {
        case .mp4:
            var settings: MP4Settings
            switch mp4Mode {
            case .targetSize:
                settings = MP4Settings(
                    rateControl: .targetSize(bytes: Int64(targetGigabytes * 1_000_000_000)),
                    codec: mp4Codec)
            case .smallHQ:
                settings = .smallHQ
            case .festivalShort:
                settings = .festivalShort
            }
            settings.subtitleURL = mp4SubtitleURL
            exporter = MP4Exporter(settings: settings)
        case .dcp:
            let primaryTitle = dcpContentTitle.isEmpty
                ? source.url.deletingPathExtension().lastPathComponent : dcpContentTitle
            // Multi-composition only when extras exist; otherwise the single
            // source flows through the Exporter protocol as today.
            let elements: [DCPElement] = dcpExtraElements.isEmpty ? [] :
                [DCPElement(source: source, title: primaryTitle)]
                + dcpExtraElements.map { DCPElement(source: $0.source, title: $0.title) }
            exporter = DCPExporter(settings: DCPSettings(
                contentTitle: primaryTitle,
                container: dcpContainer,
                j2kBitsPerSecond: Int(dcpBitrateMbps * 1_000_000),
                dcnc: dcpDCNC,
                elements: elements))
        }

        progress = nil
        phase = .exporting(source)
        beginSleepPrevention()

        exportTask = Task {
            do {
                let result = try await exporter.export(source: source) { progress in
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

    func cancelExport() {
        exportTask?.cancel()
    }

    func reset() {
        guard !isExporting else { return }
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
