// Left column: the scanners to choose from (or help when there are none) and the recent scans.
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        List(selection: scannerSelection) {
            Section("Scanners") {
                if controller.scanners.isEmpty {
                    NoScannerView {
                        controller.lookAgain()
                    }
                } else {
                    ForEach(controller.scanners) { scanner in
                        ScannerRow(scanner: scanner)
                            .tag(scanner.id)
                    }
                    .disabled(controller.status.isBusy)
                }
            }
            RecentScansSection()
        }
        .listStyle(.sidebar)
    }

    /// Selecting a row picks that scanner. Deselecting (clicking empty space) is ignored so a scanner
    /// stays selected whenever one is available.
    private var scannerSelection: Binding<ScannerInfo.ID?> {
        Binding(
            get: { controller.selectedScanner?.id },
            set: { id in
                guard let id, let scanner = controller.scanners.first(where: { $0.id == id }) else { return }
                controller.selectedScanner = scanner
            }
        )
    }
}

struct ScannerRow: View {
    let scanner: ScannerInfo

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(scanner.name)
                    .lineLimit(1)
                Text("\(scanner.transport) · \(scanner.engine.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "scanner")
        }
        .padding(.vertical, 2)
        .help("\(scanner.name), connected via \(scanner.transport)")
        .accessibilityElement(children: .combine)
    }
}

/// Shown instead of the scanner list when nothing is connected. Briefly says "Looking…" after launch
/// and after "Look again", because discovery takes a moment.
struct NoScannerView: View {
    let lookAgain: () -> Void

    @State private var attempt = 0
    @State private var isLooking = true

    var body: some View {
        VStack(spacing: 8) {
            if isLooking {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for scanners…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "scanner")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No scanner found")
                    .font(.headline)
                Text("Turn the scanner on and connect it with USB.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                Button("Look again") {
                    attempt += 1
                    lookAgain()
                }
                .accessibilityHint("Searches again for connected scanners")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .task(id: attempt) {
            isLooking = true
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
                isLooking = false
            } catch {}
        }
    }
}
