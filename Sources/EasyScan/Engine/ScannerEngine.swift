// Shared contract between the UI, the ScanController and the scanner engines.
// Engines (Image Capture, SANE) implement `ScannerEngine`; the UI only talks to `ScanController`.
import Foundation
import CoreGraphics

enum EngineKind: String, Codable, Hashable, CaseIterable {
    case imageCapture = "Image Capture"
    case sane = "SANE"
    case mock = "Mock"
}

enum ScanColorMode: String, CaseIterable, Identifiable, Codable {
    case color, gray, blackWhite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: return "Color"
        case .gray: return "Grayscale"
        case .blackWhite: return "Black & White"
        }
    }
}

enum ScanFormat: String, CaseIterable, Identifiable, Codable {
    case pdf, png, jpeg, tiff
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
    /// Uniform type identifier, as used by ImageCaptureCore's `documentUTI` and by ImageIO.
    var uti: String {
        switch self {
        case .pdf: return "com.adobe.pdf"
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .tiff: return "public.tiff"
        }
    }
}

struct ScannerInfo: Identifiable, Hashable {
    /// Stable per engine and device, e.g. "icc:<persistentID>" or "sane:<device name>".
    let id: String
    let name: String
    /// Human readable transport: "USB", "Network", …
    let transport: String
    let engine: EngineKind
}

struct ScannerCapabilities: Equatable {
    /// Supported resolutions in dpi, sorted ascending.
    var resolutions: [Int]
    var modes: [ScanColorMode]
    /// Size of the scan glass in centimeters.
    var glassSize: CGSize
}

struct ScanSettings: Equatable, Codable {
    var mode: ScanColorMode = .color
    var resolution: Int = 300
    var format: ScanFormat = .pdf
    /// Area to scan in centimeters, origin at the top-left corner of the glass. nil = whole glass.
    var area: CGRect? = nil
    var destinationFolder: URL
    /// Prefix for generated file names ("Scan" -> "Scan 2026-10-16 14.05.00.pdf").
    var namePrefix: String = "Scan"
    /// File name without extension for the next scan. ScanController fills this in before calling an engine.
    var documentName: String = ""

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Scans", isDirectory: true)
    }

    init(mode: ScanColorMode = .color, resolution: Int = 300, format: ScanFormat = .pdf, area: CGRect? = nil,
         destinationFolder: URL = ScanSettings.defaultFolder, namePrefix: String = "Scan", documentName: String = "") {
        self.mode = mode; self.resolution = resolution; self.format = format; self.area = area
        self.destinationFolder = destinationFolder; self.namePrefix = namePrefix; self.documentName = documentName
    }

    /// Full output URL for the current `documentName` and `format`.
    var outputURL: URL {
        destinationFolder.appendingPathComponent(documentName).appendingPathExtension(format.fileExtension)
    }
}

struct ScanError: LocalizedError, Equatable {
    let message: String
    let code: Int?
    init(_ message: String, code: Int? = nil) { self.message = message; self.code = code }
    var errorDescription: String? { message }
    static let cancelled = ScanError("Scan cancelled", code: -1)
}

/// A source of scanners. All methods are called on the main actor; engines hop to background queues themselves
/// for anything blocking. Long operations must honor `cancel()` by throwing `ScanError.cancelled`.
@MainActor
protocol ScannerEngine: AnyObject {
    var kind: EngineKind { get }
    /// Scanners currently available from this engine.
    var scanners: [ScannerInfo] { get }
    /// Engines call this on the main actor whenever `scanners` changes (device plugged in / removed).
    var onScannersChanged: (([ScannerInfo]) -> Void)? { get set }
    func startDiscovery()
    func stopDiscovery()
    func capabilities(of scanner: ScannerInfo) async throws -> ScannerCapabilities
    /// Quick low-resolution scan of the whole glass, for on-screen preview. Not saved to disk.
    func preview(_ scanner: ScannerInfo) async throws -> CGImage
    /// Scans one page with `settings` and writes it to `settings.outputURL` (or a URL the engine chooses in the same
    /// folder, which it returns). `progress` is 0...1 and is called on the main actor.
    func scan(_ scanner: ScannerInfo, settings: ScanSettings, progress: @escaping @MainActor (Double) -> Void) async throws -> URL
    /// Cancels an in-flight preview or scan, if any.
    func cancel()
}
