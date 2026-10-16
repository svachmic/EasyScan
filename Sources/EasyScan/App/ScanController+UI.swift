// Read-only conveniences the views use to map controller state to what they show. No new behaviour.
import Foundation
import CoreGraphics

extension ScanController {
    /// Preview and Scan can start: a scanner is selected and nothing is running.
    var canStartJob: Bool { selectedScanner != nil && !status.isBusy }

    /// The scan the next page would be appended to, when appending is possible
    /// (format is PDF and the most recent scan is a PDF).
    var appendTarget: ScanRecord? {
        guard settings.format == .pdf, let last = recentScans.first, last.format == .pdf else { return nil }
        return last
    }

    /// The preview to show. Hidden while no scanner is selected, so a stale preview of a scanner that
    /// went away does not suggest you can scan.
    var visiblePreview: CGImage? { selectedScanner == nil ? nil : previewImage }

    /// The recent-scans entry for a saved file, if it is still in the list.
    func record(for url: URL) -> ScanRecord? {
        recentScans.first { $0.url == url }
    }
}
