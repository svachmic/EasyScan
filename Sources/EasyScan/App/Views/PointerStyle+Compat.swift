// Pointer (cursor) feedback for the area selection. SwiftUI's pointerStyle needs macOS 15, so on
// macOS 14 the views simply keep the default arrow.
import SwiftUI

enum SelectionPointer {
    case crosshair
    case move
    case resize(Corner)

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    @available(macOS 15.0, *)
    var style: PointerStyle {
        switch self {
        case .crosshair: return .rectSelection
        case .move: return .grabIdle
        case .resize(let corner):
            switch corner {
            case .topLeading: return .frameResize(position: .topLeading)
            case .topTrailing: return .frameResize(position: .topTrailing)
            case .bottomLeading: return .frameResize(position: .bottomLeading)
            case .bottomTrailing: return .frameResize(position: .bottomTrailing)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func selectionPointer(_ pointer: SelectionPointer) -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(pointer.style)
        } else {
            self
        }
    }
}
