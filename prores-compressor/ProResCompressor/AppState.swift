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

    // Export configuration (persists across files within a session).
    var format: ExportFormat = .mp4
    var targetGigabytes: Double = 3.0
    var mp4Codec: MP4Settings.Codec = .hevc
    var dcpContainer: DCPContainer = .flat
    var dcpBitrateMbps: Double = 125
    var dcpContentTitle: String = ""

    private var exportTask: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?

    func load(url: URL) {
        guard !isExporting else { return }
        phase = .probing
        Task {
            do {
                let source = try await SourceProbe.probe(url: url)
                if dcpContentTitle.isEmpty {
                    dcpContentTitle = url.deletingPathExtension().lastPathComponent
                }
                phase = .configuring(source)
            } catch {
                phase = .failed(nil, error.localizedDescription)
            }
        }
    }

    func startExport() {
        guard case .configuring(let source) = phase else { return }

        let exporter: any Exporter
        switch format {
        case .mp4:
            exporter = MP4Exporter(settings: MP4Settings(
                targetBytes: Int64(targetGigabytes * 1_000_000_000),
                codec: mp4Codec))
        case .dcp:
            exporter = DCPExporter(settings: DCPSettings(
                contentTitle: dcpContentTitle.isEmpty
                    ? source.url.deletingPathExtension().lastPathComponent : dcpContentTitle,
                container: dcpContainer,
                j2kBitsPerSecond: Int(dcpBitrateMbps * 1_000_000)))
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
