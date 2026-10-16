// Writes CGImages to disk in the formats EasyScan supports. Shared by the SANE and Mock engines.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageFileWriter {
    /// Writes `image` to `url` in `format`. `dpi` is recorded in the file metadata (and sizes the PDF page).
    static func write(_ image: CGImage, to url: URL, format: ScanFormat, dpi: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch format {
        case .pdf:
            try writePDF(image, to: url, dpi: dpi)
        case .png, .jpeg, .tiff:
            guard let type = UTType(format.uti),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ScanError("Could not create \(format.label) file at \(url.path)")
            }
            var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
            if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ScanError("Could not write \(format.label) file at \(url.path)") }
        }
    }

    /// Writes a one-page PDF whose page size matches the image's physical size at `dpi`.
    static func writePDF(_ image: CGImage, to url: URL, dpi: Int) throws {
        let scale = 72.0 / Double(max(dpi, 1))
        var mediaBox = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ScanError("Could not create PDF at \(url.path)")
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
