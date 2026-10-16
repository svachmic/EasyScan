// Center column: the glass shown as a page, with the preview image, the area selection,
// a one-line hint about the selection, and a progress card while previewing or scanning.
import SwiftUI

struct PreviewArea: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let pageSize = PreviewArea.fit(aspectRatio: pageAspectRatio, in: geometry.size)
                PageView(pageSize: pageSize)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 6)

            AreaHintBar()
                .frame(height: 36)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if controller.status.isBusy {
                BusyOverlay(status: controller.status) { controller.cancel() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: controller.status.isBusy)
    }

    /// Width / height of the page: the preview image if there is one (it shows the whole glass),
    /// otherwise the glass, otherwise A4.
    private var pageAspectRatio: CGFloat {
        if let image = controller.visiblePreview, image.width > 0, image.height > 0 {
            return CGFloat(image.width) / CGFloat(image.height)
        }
        if let glass = controller.capabilities?.glassSize, glass.width > 0, glass.height > 0 {
            return glass.width / glass.height
        }
        return 21.0 / 29.7
    }

    /// The largest size with `aspectRatio` that fits in `size`.
    static func fit(aspectRatio: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, aspectRatio > 0 else { return .zero }
        let width = min(size.width, size.height * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }
}

/// The page itself: preview image (or a placeholder) with the area selection on top.
struct PageView: View {
    @EnvironmentObject private var controller: ScanController
    let pageSize: CGSize

    var body: some View {
        ZStack {
            if let image = controller.visiblePreview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                PagePlaceholder(hasScanner: controller.selectedScanner != nil)
                    .padding(24)
            }
            if let glass = controller.capabilities?.glassSize {
                AreaSelectionView(
                    area: $controller.settings.area,
                    mapping: GlassMapping(pageSize: pageSize, glassSize: glass),
                    isEditable: controller.visiblePreview != nil && !controller.status.isBusy
                )
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .background(
            Rectangle()
                .fill(Color(nsColor: controller.visiblePreview == nil ? .textBackgroundColor : .white))
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
        )
        .help(controller.visiblePreview == nil ? "" : "Drag to choose the part of the page to scan")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(controller.visiblePreview == nil ? "Empty preview" : "Preview of the scanner glass")
        .accessibilityValue(controller.settings.area.map { "Selected area \(UIText.area($0))" } ?? "Whole page")
        .accessibilityAction(named: "Scan whole page") { controller.settings.area = nil }
    }
}

struct PagePlaceholder: View {
    let hasScanner: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasScanner ? "doc.viewfinder" : "scanner")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(hasScanner
                 ? "Press Preview to see what is on the glass, or just Scan."
                 : "Connect a scanner to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
    }
}

/// One line under the page: what the selection is and how to drop it, or a tip on how to make one.
struct AreaHintBar: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        Group {
            if let area = controller.settings.area {
                // Narrow windows drop the description and keep the button.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: "crop")
                        Text("Selected area \(UIText.area(area))")
                            .monospacedDigit()
                            .fixedSize()
                        wholePageButton
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "crop")
                        wholePageButton
                    }
                }
            } else if controller.visiblePreview != nil && controller.capabilities != nil {
                ViewThatFits(in: .horizontal) {
                    Label("Drag across the page to scan only part of it.", systemImage: "hand.draw")
                        .fixedSize()
                    Label("Drag to scan part of the page.", systemImage: "hand.draw")
                        .fixedSize()
                    Text("Drag to select an area.")
                        .lineLimit(1)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var wholePageButton: some View {
        Button("Scan whole page") { controller.settings.area = nil }
            .controlSize(.small)
            .fixedSize()
            .help("Forget the selection and scan the whole glass")
    }
}

/// Covers the preview while the scanner works: progress, percentage and Cancel.
/// Takes the status as a value so that, while fading out, it keeps showing the state it was showing.
struct BusyOverlay: View {
    let status: ScanController.Status
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
            VStack(spacing: 14) {
                if case .scanning(let progress) = status {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text("Scanning… \(UIText.percent(progress))")
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Previewing…")
                }
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop the scanner (Esc or ⌘.)")
                    .accessibilityHint("Stops the current preview or scan")
            }
            .padding(24)
            .frame(minWidth: 240)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .accessibilityElement(children: .contain)
        }
    }
}
