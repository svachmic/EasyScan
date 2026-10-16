// Small text and Finder helpers shared by the views.
import Foundation
import AppKit

enum UIText {
    static func dpi(_ value: Int) -> String { "\(value) dpi" }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func centimeters(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(1)))
    }

    /// "10.0 × 5.0 cm"
    static func area(_ rect: CGRect) -> String {
        "\(centimeters(rect.width)) × \(centimeters(rect.height)) cm"
    }

    /// "3 pages · 5 minutes ago", or just the relative date for single pages.
    static func scanDetail(_ record: ScanRecord) -> String {
        let date = record.date.formatted(.relative(presentation: .named))
        return record.pageCount > 1 ? "\(record.pageCount) pages · \(date)" : date
    }

    static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

enum FinderActions {
    /// Opens `folder` in Finder, creating it first so the command also works before the first scan.
    static func showFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    static func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
