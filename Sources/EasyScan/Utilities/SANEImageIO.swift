// Turns the PNG that `scanimage` wrote into what the user asked for. Runs off the main actor (all static, no state).
import Foundation
import CoreGraphics
import ImageIO

enum SANEImageIO {
    /// Fully decodes the image at `url` into memory, so the file can be deleted right after.
    static func loadImage(at url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw ScanError("The scanner did not return an image.")
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw ScanError("The scanned image could not be read.")
        }
        return image
    }

    struct PixelSize: Equatable, Sendable {
        var width: Int
        var height: Int
    }

    /// Pixel size from the file header, without decoding the image.
    static func pixelSize(at url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return PixelSize(width: width, height: height)
    }

    /// Moves/converts the scanned PNG at `scannedPNG` to `destination` in `format`.
    /// - `crop` (centimetres, top-left origin) is applied in software for backends without geometry options.
    /// - `trimTo` cuts off padding beyond the requested size (keeping the top-left corner).
    static func export(scannedPNG: URL, to destination: URL, format: ScanFormat, dpi: Int, crop: CGRect?,
                       trimTo maxPixels: PixelSize?) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oversized = maxPixels.flatMap { limit in
            pixelSize(at: scannedPNG).map { $0.width > limit.width || $0.height > limit.height }
        } ?? false
        if format == .png && crop == nil && !oversized {
            // scanimage's PNG already carries the resolution (pHYs chunk); no need to re-encode.
            try FileManager.default.moveItem(at: scannedPNG, to: destination)
            return
        }
        var image = try loadImage(at: scannedPNG)
        if let crop {
            image = cropped(image, toCentimeters: crop, dpi: dpi)
        } else {
            image = trimmed(image, toMax: maxPixels)
        }
        if format == .jpeg { image = expandedTo8Bit(image) }
        try ImageFileWriter.write(image, to: destination, format: format, dpi: dpi)
    }

    /// Crops `image` (scanned at `dpi`, covering the whole glass) to `area` in centimetres.
    static func cropped(_ image: CGImage, toCentimeters area: CGRect, dpi: Int) -> CGImage {
        let pixelsPerCm = Double(dpi) / 2.54
        let rect = CGRect(x: area.minX * pixelsPerCm, y: area.minY * pixelsPerCm,
                          width: area.width * pixelsPerCm, height: area.height * pixelsPerCm)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return image }
        return image.cropping(to: rect) ?? image
    }

    /// Keeps at most `maxPixels` of `image`, anchored at the top-left corner.
    static func trimmed(_ image: CGImage, toMax maxPixels: PixelSize?) -> CGImage {
        guard let maxPixels, image.width > maxPixels.width || image.height > maxPixels.height else { return image }
        let rect = CGRect(x: 0, y: 0, width: min(image.width, maxPixels.width), height: min(image.height, maxPixels.height))
        return image.cropping(to: rect) ?? image
    }

    /// JPEG cannot hold 1-bit images (Lineart scans); redraw those as 8-bit grayscale.
    static func expandedTo8Bit(_ image: CGImage) -> CGImage {
        guard image.bitsPerComponent < 8 else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// `url` if nothing exists there yet, otherwise "name-2.ext", "name-3.ext", … in the same folder.
    static func unusedURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base)-\(index)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
