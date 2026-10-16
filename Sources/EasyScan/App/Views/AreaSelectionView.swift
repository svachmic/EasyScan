// Lets the user drag out the area to scan on top of the preview page, then move it or resize it by
// its corners. Draws the selection as a dashed rectangle and dims everything outside it.
// Works in page points while dragging and writes centimeters to `area` when a drag ends.
import SwiftUI

struct AreaSelectionView: View {
    @Binding var area: CGRect?
    let mapping: GlassMapping
    let isEditable: Bool

    /// The rectangle being drawn, moved or resized, in page points. nil when no drag is in progress.
    @State private var liveRect: CGRect?
    /// The selection at the moment a move or resize began.
    @State private var dragOrigin: CGRect?

    private static let space = "EasyScan.page"
    private static let minimumSide: CGFloat = 6

    var body: some View {
        if mapping.isValid {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drawGesture)
                    .selectionPointer(.crosshair)
                    .allowsHitTesting(isEditable)

                if let rect = selection {
                    SelectionShade(selection: rect)
                        .fill(Color.black.opacity(0.28), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    selectionBody(rect)
                    if isEditable {
                        ForEach(SelectionPointer.Corner.allCases, id: \.self) { corner in
                            handle(corner, of: rect)
                        }
                    }
                    if liveRect != nil {
                        sizeLabel(for: rect)
                    }
                }
            }
            .frame(width: mapping.pageSize.width, height: mapping.pageSize.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
        }
    }

    /// What to draw: the live drag, or the stored area converted to page points, clipped to the page.
    private var selection: CGRect? {
        guard let rect = liveRect ?? area.map(mapping.viewRect(fromCentimeters:)) else { return nil }
        let clipped = rect.intersection(mapping.pageBounds)
        return clipped.isNull || clipped.width < 1 || clipped.height < 1 ? nil : clipped
    }

    // MARK: Pieces

    private func selectionBody(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.06))
            .overlay(
                Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .gesture(moveGesture(rect))
            .selectionPointer(.move)
            .allowsHitTesting(isEditable)
            .position(x: rect.midX, y: rect.midY)
    }

    private func handle(_ corner: SelectionPointer.Corner, of rect: CGRect) -> some View {
        let point = corner.point(in: rect)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(resizeGesture(corner, rect))
            .selectionPointer(.resize(corner))
            .position(point)
    }

    private func sizeLabel(for rect: CGRect) -> some View {
        Text(UIText.area(mapping.centimeterRect(fromView: rect)))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
            .position(x: min(max(rect.midX, 50), mapping.pageSize.width - 50),
                      y: rect.minY > 24 ? rect.minY - 14 : min(rect.maxY + 14, mapping.pageSize.height - 12))
            .allowsHitTesting(false)
    }

    // MARK: Gestures

    /// Drag on empty page: draw a new selection.
    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                liveRect = CGRect(spanning: clamp(value.startLocation), clamp(value.location))
            }
            .onEnded { _ in commit() }
    }

    /// Drag inside the selection: move it, keeping it on the page.
    private func moveGesture(_ rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = beginDrag(from: rect)
                var moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(moved.minX, 0), mapping.pageSize.width - moved.width)
                moved.origin.y = min(max(moved.minY, 0), mapping.pageSize.height - moved.height)
                liveRect = moved
            }
            .onEnded { _ in commit() }
    }

    /// Drag a corner handle: resize, with the opposite corner fixed.
    private func resizeGesture(_ corner: SelectionPointer.Corner, _ rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = beginDrag(from: rect)
                let grabbed = corner.point(in: start)
                let moved = clamp(CGPoint(x: grabbed.x + value.translation.width, y: grabbed.y + value.translation.height))
                liveRect = CGRect(spanning: corner.opposite.point(in: start), moved)
            }
            .onEnded { _ in commit() }
    }

    private func beginDrag(from rect: CGRect) -> CGRect {
        if let origin = dragOrigin { return origin }
        dragOrigin = rect
        return rect
    }

    /// Stores the finished drag as centimeters. Tiny rectangles (a click) are ignored, and a rectangle
    /// covering the whole glass is stored as nil, which means "whole page".
    private func commit() {
        if let rect = liveRect, rect.width >= Self.minimumSide, rect.height >= Self.minimumSide {
            let centimeters = mapping.centimeterRect(fromView: rect)
            area = mapping.coversWholeGlass(centimeters) ? nil : centimeters
        }
        liveRect = nil
        dragOrigin = nil
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), mapping.pageSize.width),
                y: min(max(point.y, 0), mapping.pageSize.height))
    }
}

/// The page with a rectangular hole: fill with even-odd to dim everything outside the selection.
private struct SelectionShade: Shape {
    var selection: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(selection)
        return path
    }
}

private extension SelectionPointer.Corner {
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeading: return CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    var opposite: SelectionPointer.Corner {
        switch self {
        case .topLeading: return .bottomTrailing
        case .topTrailing: return .bottomLeading
        case .bottomLeading: return .topTrailing
        case .bottomTrailing: return .topLeading
        }
    }
}

private extension CGRect {
    /// The rectangle with corners `a` and `b`, in any order.
    init(spanning a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
