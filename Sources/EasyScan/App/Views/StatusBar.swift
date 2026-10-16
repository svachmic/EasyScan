// Bottom line of the window: what EasyScan is doing, the file it just saved, or an error to dismiss.
import SwiftUI

struct StatusBar: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        if case .failed(let message) = controller.status {
            ErrorBanner(message: message) { controller.clearError() }
        } else {
            HStack(spacing: 8) {
                icon
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
                Spacer(minLength: 8)
                if case .finished(let url) = controller.status {
                    Button("Open") { open(url) }
                        .help("Open the file in its default app")
                    Button("Show in Finder") { reveal(url) }
                        .help("Show the file in Finder")
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .accessibilityElement(children: .contain)
        }
    }

    private var text: String {
        switch controller.status {
        case .idle: return controller.selectedScanner == nil ? "No scanner connected" : "Ready"
        case .previewing: return "Previewing…"
        case .scanning(let progress): return "Scanning… \(UIText.percent(progress))"
        case .finished(let url): return "Saved \(url.lastPathComponent)"
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var icon: some View {
        switch controller.status {
        case .previewing, .scanning:
            ProgressView().controlSize(.mini)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            Image(systemName: controller.selectedScanner == nil ? "circle.dashed" : "circle.fill")
                .foregroundStyle(controller.selectedScanner == nil ? Color.secondary : Color.green)
                .imageScale(.small)
        }
    }

    private func open(_ url: URL) {
        if let record = controller.record(for: url) { controller.open(record) } else { NSWorkspace.shared.open(url) }
    }

    private func reveal(_ url: URL) {
        if let record = controller.record(for: url) { controller.reveal(record) } else { FinderActions.reveal(url) }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .help("Hide this message (Esc)")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 32)
        .background(Color.red.opacity(0.13))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(message)")
    }
}
