// Converts between the on-screen page (points, origin top-left) and the scanner glass
// (centimeters, origin top-left), which is how ScanSettings.area is expressed.
import CoreGraphics

struct GlassMapping {
    let pageSize: CGSize
    let glassSize: CGSize

    var isValid: Bool {
        pageSize.width > 0 && pageSize.height > 0 && glassSize.width > 0 && glassSize.height > 0
    }

    var pageBounds: CGRect { CGRect(origin: .zero, size: pageSize) }

    func viewRect(fromCentimeters rect: CGRect) -> CGRect {
        let sx = pageSize.width / glassSize.width
        let sy = pageSize.height / glassSize.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }

    /// The glass area under `rect`, rounded to whole millimeters and clamped to the glass.
    func centimeterRect(fromView rect: CGRect) -> CGRect {
        let sx = glassSize.width / pageSize.width
        let sy = glassSize.height / pageSize.height
        let x0 = millimeters(rect.minX * sx, limit: glassSize.width)
        let y0 = millimeters(rect.minY * sy, limit: glassSize.height)
        let x1 = millimeters(rect.maxX * sx, limit: glassSize.width)
        let y1 = millimeters(rect.maxY * sy, limit: glassSize.height)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }

    /// True when a centimeter rect covers practically the whole glass, i.e. it means "scan the whole page".
    func coversWholeGlass(_ rect: CGRect) -> Bool {
        rect.width >= glassSize.width - 0.2 && rect.height >= glassSize.height - 0.2
    }

    private func millimeters(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        min(max((value * 10).rounded() / 10, 0), limit)
    }
}
