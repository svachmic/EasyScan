// The single object the UI observes. Aggregates engines, owns settings, runs previews/scans, keeps recent scans.
import Foundation
import AppKit
import PDFKit
import ImageIO

struct ScanRecord: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let date: Date
    let format: ScanFormat
    var pageCount: Int
    var thumbnail: CGImage?

    static func == (a: ScanRecord, b: ScanRecord) -> Bool { a.id == b.id && a.pageCount == b.pageCount }
    var fileName: String { url.lastPathComponent }
}

@MainActor
final class ScanController: ObservableObject {
    enum Status: Equatable {
        case idle
        case previewing
        case scanning(progress: Double)
        case finished(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .previewing, .scanning: return true
            default: return false
            }
        }
    }

    @Published private(set) var scanners: [ScannerInfo] = []
    @Published var selectedScanner: ScannerInfo? {
        didSet {
            if selectedScanner?.id != oldValue?.id {
                previewImage = nil   // a preview belongs to one glass; never show scanner A's page for scanner B
                Task { await loadCapabilities() }
            }
        }
    }
    @Published private(set) var capabilities: ScannerCapabilities?
    @Published var settings: ScanSettings { didSet { saveSettings() } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var recentScans: [ScanRecord] = []
    /// When on and the format is PDF, the next scan is appended as a new page to the most recent PDF.
    @Published var appendToLastPDF = false

    let engines: [any ScannerEngine]
    private let defaults = UserDefaults.standard
    private let settingsKey = "EasyScan.settings"

    init(engines: [any ScannerEngine]) {
        self.engines = engines
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(ScanSettings.self, from: data) {
            settings = saved
        } else {
            settings = ScanSettings()
        }
        settings.documentName = ""
    }

    // MARK: Discovery

    /// Starts discovery. Image Capture (and the mock) start immediately; SANE is a fallback and is only started
    /// when no other engine has found a scanner after a short grace period (probing SANE opens the USB device and
    /// could disturb an Image Capture session), or when the user explicitly asks to look again.
    func start() {
        for engine in engines where engine.kind != .sane {
            engine.onScannersChanged = { [weak self] _ in self?.refreshScanners() }
            engine.startDiscovery()
        }
        refreshScanners()
        fallbackTask?.cancel()
        guard fallbackStartedAt == nil else { return }   // SANE is already running; do not probe it again
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.scanners.isEmpty { self.startFallbackEngines() }
        }
    }

    /// Re-runs discovery on every engine, including SANE. Bound to the "Look again" button.
    func lookAgain() {
        start()
        // A SANE probe takes a few seconds; a second one on top of it would just kill the first.
        if scanners.isEmpty, (fallbackStartedAt.map { Date().timeIntervalSince($0) > 8 } ?? true) { startFallbackEngines() }
    }

    private var fallbackTask: Task<Void, Never>?
    private var fallbackStartedAt: Date?

    private func startFallbackEngines() {
        fallbackTask?.cancel()
        fallbackStartedAt = Date()
        for engine in engines where engine.kind == .sane {
            engine.onScannersChanged = { [weak self] _ in self?.refreshScanners() }
            engine.startDiscovery()
        }
        refreshScanners()
    }

    func stop() {
        fallbackTask?.cancel()
        fallbackStartedAt = nil
        engines.forEach { $0.cancel() }   // a quitting app must not leave a scan (or a scanimage process) running
        engines.forEach { $0.stopDiscovery() }
    }

    func refreshScanners() {
        scanners = engines.flatMap { $0.scanners }
        if let selected = selectedScanner {
            // Match by id: a renamed device is still the same device, so keep it (and its preview) selected.
            if let current = scanners.first(where: { $0.id == selected.id }) {
                if current != selected { selectedScanner = current }
            } else {
                selectedScanner = nil
            }
        }
        if selectedScanner == nil { selectedScanner = scanners.first }
    }

    private func engine(for scanner: ScannerInfo) -> (any ScannerEngine)? {
        engines.first { $0.kind == scanner.engine }
    }

    func loadCapabilities() async {
        guard let scanner = selectedScanner, let engine = engine(for: scanner) else { capabilities = nil; return }
        do {
            let caps = try await engine.capabilities(of: scanner)
            // The user may have switched scanners while this was in flight; a late answer must not win.
            guard selectedScanner?.id == scanner.id else { return }
            capabilities = caps
            if !caps.resolutions.contains(settings.resolution) {
                settings.resolution = caps.resolutions.min { abs($0 - settings.resolution) < abs($1 - settings.resolution) } ?? settings.resolution
            }
            if !caps.modes.contains(settings.mode) { settings.mode = caps.modes.first ?? .color }
            settings.area = clamp(settings.area, to: caps.glassSize)
        } catch {
            guard selectedScanner?.id == scanner.id else { return }
            capabilities = nil
            if !status.isBusy { status = .failed(error.localizedDescription) }
        }
    }

    // MARK: Actions

    func preview() async {
        guard let scanner = selectedScanner, let engine = engine(for: scanner), !status.isBusy else { return }
        status = .previewing
        do {
            previewImage = try await engine.preview(scanner)
            status = .idle
        } catch let error as ScanError where error == .cancelled {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func scan() async {
        guard let scanner = selectedScanner, let engine = engine(for: scanner), !status.isBusy else { return }
        status = .scanning(progress: 0)
        // Decide the append target now; the list can change while the scanner is busy.
        let target: ScanRecord? = {
            guard appendToLastPDF, settings.format == .pdf, let last = recentScans.first,
                  last.format == .pdf, FileManager.default.fileExists(atPath: last.url.path) else { return nil }
            return last
        }()
        let appending = target != nil
        var job = settings
        if appending {
            job.destinationFolder = FileManager.default.temporaryDirectory
            job.documentName = "EasyScan-page-\(UUID().uuidString)"
        } else {
            job.documentName = uniqueDocumentName(prefix: settings.namePrefix, in: settings.destinationFolder, ext: settings.format.fileExtension)
        }
        do {
            try FileManager.default.createDirectory(at: job.destinationFolder, withIntermediateDirectories: true)
            let url = try await engine.scan(scanner, settings: job) { [weak self] p in
                self?.status = .scanning(progress: min(max(p, 0), 1))
            }
            if let target {
                do {
                    let count = try appendPDF(at: url, to: target.url)
                    try? FileManager.default.removeItem(at: url)
                    if let i = recentScans.firstIndex(where: { $0.id == target.id }) { recentScans[i].pageCount = count }
                    status = .finished(target.url)
                } catch {
                    // The target vanished or could not be rewritten: keep the page as a scan of its own.
                    let name = uniqueDocumentName(prefix: settings.namePrefix, in: settings.destinationFolder, ext: job.format.fileExtension)
                    let rescued = settings.destinationFolder.appendingPathComponent(name).appendingPathExtension(job.format.fileExtension)
                    try FileManager.default.createDirectory(at: settings.destinationFolder, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: rescued)
                    addRecord(for: rescued, format: job.format)
                    status = .failed("Could not add the page to \(target.fileName) (\(error.localizedDescription)). It was saved as \(rescued.lastPathComponent) instead.")
                }
            } else {
                addRecord(for: url, format: job.format)
                status = .finished(url)
            }
        } catch let error as ScanError where error == .cancelled {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        engines.forEach { $0.cancel() }
    }

    func clearError() {
        if case .failed = status { status = .idle }
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.destinationFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { settings.destinationFolder = url }
    }

    func reveal(_ record: ScanRecord) { reveal(url: record.url) }
    func open(_ record: ScanRecord) { open(url: record.url) }
    func reveal(url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func open(url: URL) { NSWorkspace.shared.open(url) }
    func remove(_ record: ScanRecord) { recentScans.removeAll { $0.id == record.id } }

    // MARK: Helpers

    /// Keeps a selected area inside the glass. An area that is empty or covers the whole glass becomes nil.
    private func clamp(_ area: CGRect?, to glass: CGSize) -> CGRect? {
        guard let area, glass.width > 0, glass.height > 0 else { return nil }
        let clipped = area.intersection(CGRect(origin: .zero, size: glass))
        if clipped.isNull || clipped.width < 0.1 || clipped.height < 0.1 { return nil }
        if clipped.width >= glass.width - 0.05 && clipped.height >= glass.height - 0.05 { return nil }
        return clipped
    }

    private func saveSettings() {
        if SelfTest.isRequested { return }   // a killed self-test must not leave its temp folder as the destination
        var copy = settings
        copy.documentName = ""
        if let data = try? JSONEncoder().encode(copy) { defaults.set(data, forKey: settingsKey) }
    }

    private func uniqueDocumentName(prefix: String, in folder: URL, ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(prefix.trimmingCharacters(in: .whitespaces).isEmpty ? "Scan" : prefix.trimmingCharacters(in: .whitespaces)) \(f.string(from: Date()))"
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).appendingPathExtension(ext).path) {
            name = "\(base)-\(n)"; n += 1
        }
        return name
    }

    /// Appends all pages of the PDF at `source` to the PDF at `target`. Returns the new page count.
    private func appendPDF(at source: URL, to target: URL) throws -> Int {
        guard let doc = PDFDocument(url: target) else { throw ScanError("Could not open \(target.lastPathComponent)") }
        guard let extra = PDFDocument(url: source) else { throw ScanError("Could not read the scanned page") }
        for i in 0..<extra.pageCount {
            if let page = extra.page(at: i) { doc.insert(page, at: doc.pageCount) }
        }
        // Write next to the original and swap, so a failed write can never truncate the existing document.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard doc.write(to: staging) else { throw ScanError("Could not save \(target.lastPathComponent)") }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw ScanError("Could not replace \(target.lastPathComponent): \(error.localizedDescription)")
        }
        return doc.pageCount
    }

    private func addRecord(for url: URL, format: ScanFormat) {
        let record = ScanRecord(id: UUID(), url: url, date: Date(), format: format,
                                pageCount: format == .pdf ? (PDFDocument(url: url)?.pageCount ?? 1) : 1,
                                thumbnail: ScanController.thumbnail(for: url, format: format))
        recentScans.insert(record, at: 0)
        if recentScans.count > 50 { recentScans.removeLast() }
    }

    static func thumbnail(for url: URL, format: ScanFormat, maxPixels: Int = 320) -> CGImage? {
        if format == .pdf {
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = Double(maxPixels) / max(bounds.width, bounds.height, 1)
            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }
}
