// A fake scanner for developing the UI without hardware. Produces a synthetic page.
import Foundation
import CoreGraphics

@MainActor
final class MockEngine: ScannerEngine {
    let kind: EngineKind = .mock
    private(set) var scanners: [ScannerInfo] = []
    var onScannersChanged: (([ScannerInfo]) -> Void)?
    private var cancelled = false

    func startDiscovery() {
        scanners = [ScannerInfo(id: "mock:1", name: "Mock Scanner 9000", transport: "USB", engine: .mock)]
        onScannersChanged?(scanners)
    }

    func stopDiscovery() {
        scanners = []
        onScannersChanged?(scanners)
    }

    func capabilities(of scanner: ScannerInfo) async throws -> ScannerCapabilities {
        ScannerCapabilities(resolutions: [75, 100, 150, 200, 300, 600], modes: ScanColorMode.allCases,
                            glassSize: CGSize(width: 21.6, height: 29.7))
    }

    func preview(_ scanner: ScannerInfo) async throws -> CGImage {
        cancelled = false
        try await Task.sleep(nanoseconds: 800_000_000)
        if cancelled { throw ScanError.cancelled }
        return try MockEngine.makePage(width: 432, height: 594, mode: .color)
    }

    func scan(_ scanner: ScannerInfo, settings: ScanSettings, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        cancelled = false
        for i in 1...10 {
            try await Task.sleep(nanoseconds: 120_000_000)
            if cancelled { throw ScanError.cancelled }
            progress(Double(i) / 10)
        }
        let pxPerCm = Double(settings.resolution) / 2.54
        let area = settings.area ?? CGRect(x: 0, y: 0, width: 21.6, height: 29.7)
        let image = try MockEngine.makePage(width: Int(area.width * pxPerCm), height: Int(area.height * pxPerCm), mode: settings.mode)
        let url = settings.outputURL
        try ImageFileWriter.write(image, to: url, format: settings.format, dpi: settings.resolution)
        return url
    }

    func cancel() { cancelled = true }

    /// Draws a white page with a few colored blocks and lines, so previews and files are visibly "scans".
    static func makePage(width: Int, height: Int, mode: ScanColorMode) throws -> CGImage {
        let w = max(width, 8), h = max(height, 8)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScanError("Could not create bitmap")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let colors: [CGColor] = mode == .color
            ? [CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1), CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.75, blue: 0.1, alpha: 1)]
            : [CGColor(gray: 0.2, alpha: 1), CGColor(gray: 0.5, alpha: 1), CGColor(gray: 0.75, alpha: 1)]
        let m = Double(w) * 0.08
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: m + Double(i) * m * 3, y: Double(h) - m * 4, width: m * 2.4, height: m * 2.4))
        }
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        var y = Double(h) - m * 6
        while y > m {
            ctx.fill(CGRect(x: m, y: y, width: Double(w) - 2 * m - Double.random(in: 0...(m * 4)), height: m * 0.25))
            y -= m * 0.7
        }
        guard let image = ctx.makeImage() else { throw ScanError("Could not render page") }
        return image
    }
}
