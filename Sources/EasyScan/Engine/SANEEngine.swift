// Scanner engine backed by SANE (sane-backends from Homebrew), driven through the `scanimage` command-line tool.
//
// Why a CLI and not libsane: scanimage is native arm64, needs no bridging header or code signing tricks, and a crash
// in a backend cannot take the app down. Every call is one short-lived `scanimage` process:
//
//   discovery     scanimage -L                                  (one-shot, never polled; see startDiscovery)
//   capabilities  scanimage -d NAME --help                      (cached per device)
//   preview       scanimage -d NAME --mode Color --resolution <lowest> -l/-t/-x/-y <glass> --format=png -o tmp
//   scan          scanimage -d NAME --mode M --resolution N -l/-t/-x/-y <area> --format=png --progress -o tmp
//
// Only one scanimage touches the device at a time (`acquireDevice`), and at most one preview/scan is in flight
// (`activeJob`); a second one fails fast with "Scanner is busy".
import Foundation
import CoreGraphics
import os

@MainActor
final class SANEEngine: ScannerEngine {
    let kind: EngineKind = .sane
    private(set) var scanners: [ScannerInfo] = []
    var onScannersChanged: (([ScannerInfo]) -> Void)?

    private let logger = Logger(subsystem: "EasyScan", category: "SANE")

    /// Parsed `--help` output per ScannerInfo.id. Only successful parses are cached.
    private var profiles: [String: SANEDeviceProfile] = [:]
    /// ScannerInfo.id -> current SANE device name, for devices whose USB address changed since discovery
    /// (the printer was power-cycled), so the ScannerInfo the UI holds keeps working.
    private var renamedDevices: [String: String] = [:]

    /// The preview/scan in flight, if any.
    private var activeJob: SANEJob?

    /// Serializes every scanimage run that opens the device (discovery, --help, preview, scan).
    private var deviceInUse = false
    private var deviceWaiters: [CheckedContinuation<Void, Never>] = []

    private var discoveryTask: Task<Void, Never>?
    private var discoveryGeneration = 0

    // Timeouts (seconds). Scans are slow: 600 dpi color A4 over USB 2.0 takes minutes.
    private enum Timeout {
        static let list: TimeInterval = 20
        static let help: TimeInterval = 30
        static let preview: TimeInterval = 180
        static let scan: TimeInterval = 30 * 60
    }

    init() {}

    // MARK: - Locating scanimage

    /// Where scanimage lives: Homebrew (Apple Silicon, then Intel), then PATH, then MacPorts. Computed on every call
    /// so installing SANE while the app runs is picked up by the next refresh.
    nonisolated static var executableURL: URL? {
        let fileManager = FileManager.default
        var candidates = ["/opt/homebrew/bin/scanimage", "/usr/local/bin/scanimage"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/scanimage" }
        candidates.append("/opt/local/bin/scanimage")
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    nonisolated static var isAvailable: Bool { executableURL != nil }

    // MARK: - Discovery

    /// Runs `scanimage -L` once. Deliberately not periodic: listing opens every USB scanner, which would interfere
    /// with the Image Capture engine using the same device. Call `refresh()` to look again.
    func startDiscovery() { runDiscovery() }

    /// Re-runs discovery (e.g. from a "Refresh" button).
    func refresh() { runDiscovery() }

    func stopDiscovery() {
        discoveryGeneration += 1 // makes any in-flight discovery result stale
        discoveryTask?.cancel()
        discoveryTask = nil
        scanners = []
        onScannersChanged?(scanners)
    }

    private func runDiscovery() {
        discoveryGeneration += 1
        let generation = discoveryGeneration
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.acquireDevice()
            let listings = Task.isCancelled ? nil : await self.listDevices(job: nil)
            self.releaseDevice()
            guard generation == self.discoveryGeneration, !Task.isCancelled else { return }
            if let listings {
                self.applyDiscovered(listings)
            } else {
                // Listing failed (timeout or scanimage error): keep what we had, but still tell observers we're done.
                self.onScannersChanged?(self.scanners)
            }
        }
    }

    /// `scanimage -L`. nil = the listing itself failed (or `job` was cancelled); [] = no devices.
    /// Caller must hold the device.
    private func listDevices(job: SANEJob?) async -> [SANEDeviceListing]? {
        guard Self.isAvailable else { return [] }
        do {
            let result = try await execute(["-L"], timeout: Timeout.list, job: job)
            let listings = SANEParsing.parseDeviceList(result.stdoutText)
            if !result.succeeded && listings.isEmpty {
                logger.error("scanimage -L failed (\(result.exitCode)): \(result.stderrText, privacy: .public)")
                return nil
            }
            return listings
        } catch {
            logger.error("scanimage -L failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func applyDiscovered(_ listings: [SANEDeviceListing]) {
        scanners = listings.map(Self.scannerInfo(for:))
        let ids = Set(scanners.map(\.id))
        profiles = profiles.filter { ids.contains($0.key) }
        renamedDevices = renamedDevices.filter { ids.contains($0.key) }
        logger.info("SANE discovery found \(self.scanners.count) scanner(s)")
        onScannersChanged?(scanners)
    }

    private static func scannerInfo(for listing: SANEDeviceListing) -> ScannerInfo {
        ScannerInfo(id: "sane:" + listing.name, name: displayName(for: listing),
                    transport: SANEParsing.transport(forDeviceName: listing.name), engine: .sane)
    }

    private static func displayName(for listing: SANEDeviceListing) -> String {
        SANEParsing.cleanDescription(listing.description) + " (SANE)"
    }

    // MARK: - Capabilities

    func capabilities(of scanner: ScannerInfo) async throws -> ScannerCapabilities {
        if let cached = profiles[scanner.id] { return cached.capabilities }
        guard Self.isAvailable else { throw Self.notInstalledError }
        await acquireDevice()
        defer { releaseDevice() }
        return try await profile(for: scanner, job: nil).capabilities
    }

    /// Cached profile, or `scanimage --help` parsed into one. Caller must hold the device.
    /// - Without a `job` (capabilities) it never throws: if the device can't be queried right now (busy, unplugged,
    ///   odd help text) it returns sensible defaults, uncached, so the next call tries again.
    /// - With a `job` (preview/scan) the help run is cancellable, and a device that can't be reached is reported
    ///   right away, since the scan itself would fail the same way.
    private func profile(for scanner: ScannerInfo, job: SANEJob?) async throws -> SANEDeviceProfile {
        if let cached = profiles[scanner.id] { return cached }
        do {
            let result = try await runOnDevice(scanner, job: job, timeout: Timeout.help) { ["-d", $0, "--help"] }
            let options = SANEParsing.parseHelp(result.stdoutText)
            if options.foundDeviceSection {
                let profile = SANEDeviceProfile(options: options)
                profiles[scanner.id] = profile
                logger.info("SANE capabilities for \(scanner.name, privacy: .public): \(String(describing: profile.capabilities), privacy: .public)")
                return profile
            }
            logger.error("scanimage --help gave no device options: \(result.stderrText, privacy: .public)")
            // scanimage prints its generic help and exits 0 even when the device could not be opened.
            if job != nil, !SANEParsing.meaningfulLines(of: result.stderrText).isEmpty {
                throw SANEParsing.friendlyError(stderr: result.stderrText, exitCode: result.exitCode,
                                                scannerName: Self.plainName(scanner))
            }
        } catch {
            if job != nil { throw error }
            logger.error("scanimage --help failed: \(error.localizedDescription, privacy: .public)")
        }
        return SANEDeviceProfile(options: SANEDeviceOptions())
    }

    // MARK: - Preview

    func preview(_ scanner: ScannerInfo) async throws -> CGImage {
        let job = try beginJob(progress: nil)
        defer { endJob(job) }
        await acquireDevice()
        defer { releaseDevice() }
        try job.throwIfCancelled()

        let profile = try await profile(for: scanner, job: job)
        let workFolder = try Self.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: workFolder) }
        let output = workFolder.appendingPathComponent("preview.png")
        let dpi = profile.capabilities.resolutions.first ?? 75
        let geometry = try profile.geometry(for: nil)

        let result = try await runOnDevice(scanner, job: job, timeout: Timeout.preview) { device in
            ["-d", device, "--mode", profile.modeName(for: .color), "--resolution", String(dpi)]
                + profile.sourceArguments + geometry.arguments + ["--format=png", "-o", output.path]
        }
        try checkSucceeded(result, output: output, scanner: scanner)
        let maxPixels = geometry.expectedPixels(dpi: dpi)
        let image = try await Task.detached(priority: .userInitiated) {
            SANEImageIO.trimmed(try SANEImageIO.loadImage(at: output), toMax: maxPixels)
        }.value
        try job.throwIfCancelled()
        return image
    }

    // MARK: - Scan

    func scan(_ scanner: ScannerInfo, settings: ScanSettings,
              progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let job = try beginJob(progress: progress)
        defer { endJob(job) }
        await acquireDevice()
        defer { releaseDevice() }
        try job.throwIfCancelled()

        let profile = try await profile(for: scanner, job: job)
        let dpi = profile.resolution(nearest: settings.resolution)
        let mode = profile.modeName(for: settings.mode)
        let geometry = try profile.geometry(for: settings.area)
        let workFolder = try Self.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: workFolder) }
        let output = workFolder.appendingPathComponent("scan.png")

        let result = try await runOnDevice(scanner, job: job, timeout: Timeout.scan) { device in
            ["-d", device, "--mode", mode, "--resolution", String(dpi)]
                + profile.sourceArguments + geometry.arguments + ["--format=png", "--progress", "-o", output.path]
        }
        try checkSucceeded(result, output: output, scanner: scanner)
        try job.throwIfCancelled()

        var target = settings
        if target.documentName.isEmpty { target.documentName = Self.fallbackDocumentName(prefix: settings.namePrefix) }
        let destination = SANEImageIO.unusedURL(for: target.outputURL)
        let format = settings.format
        let crop = geometry.softwareCrop
        let maxPixels = geometry.expectedPixels(dpi: dpi)
        try await Task.detached(priority: .userInitiated) {
            try SANEImageIO.export(scannedPNG: output, to: destination, format: format, dpi: dpi,
                                   crop: crop, trimTo: maxPixels)
        }.value
        if job.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw ScanError.cancelled
        }
        progress(1)
        logger.info("SANE scan saved to \(destination.path, privacy: .public)")
        return destination
    }

    // MARK: - Cancel

    func cancel() {
        guard let job = activeJob else { return }
        logger.info("Cancelling SANE operation")
        job.cancel()
    }

    // MARK: - Running scanimage

    /// Runs scanimage once. Throws `.cancelled` if the job was cancelled, a timeout error if the watchdog fired;
    /// otherwise returns the result whatever the exit code.
    private func execute(_ arguments: [String], timeout: TimeInterval, job: SANEJob?) async throws -> SANEProcessResult {
        guard let executable = Self.executableURL else { throw Self.notInstalledError }
        if job?.isCancelled == true { throw ScanError.cancelled }

        var onProgress: (@Sendable (Double) -> Void)?
        if let job, job.progressHandler != nil {
            let jobID = job.id
            onProgress = { fraction in
                // FIFO hop to the main actor so updates arrive in order (and before the scan's result).
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.forwardProgress(fraction, jobID: jobID) }
                }
            }
        }
        let process = SANEProcess(executableURL: executable, arguments: arguments, timeout: timeout, onProgress: onProgress)
        job?.process = process
        defer { job?.process = nil }
        logger.debug("Running \(process.commandLine, privacy: .public)")

        let result = try await process.run()
        logger.debug("scanimage exited with \(result.exitCode)")
        if result.wasCancelled || job?.isCancelled == true { throw ScanError.cancelled }
        if result.timedOut {
            throw ScanError("The scanner did not respond in time. Turn it off and on again, then try again.")
        }
        return result
    }

    /// Runs scanimage against `scanner`'s device. If the device cannot be opened because it is no longer listed
    /// under that name (USB address changes when the printer is power-cycled), looks it up again by description and
    /// retries once under the new name. Caller must hold the device.
    private func runOnDevice(_ scanner: ScannerInfo, job: SANEJob?, timeout: TimeInterval,
                             arguments: (String) -> [String]) async throws -> SANEProcessResult {
        let device = deviceName(for: scanner)
        let result = try await execute(arguments(device), timeout: timeout, job: job)
        guard SANEParsing.indicatesUnreachableDevice(result.stderrText) else { return result }

        logger.info("\(device, privacy: .public) could not be opened; looking for it under a new name")
        guard let listings = await listDevices(job: job) else {
            try job?.throwIfCancelled()
            return result
        }
        try job?.throwIfCancelled()
        let backend = Self.backend(of: device)
        guard let moved = listings.first(where: {
            $0.name != device && Self.backend(of: $0.name) == backend && Self.displayName(for: $0) == scanner.name
        }) else {
            if listings.contains(where: { $0.name == device }) { return result } // still there: report the real error
            throw ScanError("“\(Self.plainName(scanner))” was not found. Make sure it is turned on and connected, then try again.")
        }
        logger.info("\(scanner.name, privacy: .public) is now \(moved.name, privacy: .public)")
        renamedDevices[scanner.id] = moved.name
        return try await execute(arguments(moved.name), timeout: timeout, job: job)
    }

    /// Throws a friendly ScanError if scanimage failed or did not produce `output`.
    private func checkSucceeded(_ result: SANEProcessResult, output: URL, scanner: ScannerInfo) throws {
        if !result.succeeded {
            logger.error("scanimage failed (\(result.exitCode)): \(result.stderrText, privacy: .public)")
            throw SANEParsing.friendlyError(stderr: result.stderrText, exitCode: result.exitCode, scannerName: Self.plainName(scanner))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        if size == 0 {
            let tail = SANEParsing.meaningfulLines(of: result.stderrText).suffix(2).joined(separator: " ")
            throw ScanError("The scanner did not return an image." + (tail.isEmpty || tail.count > 200 ? "" : " (\(tail))"))
        }
    }

    private func forwardProgress(_ fraction: Double, jobID: UUID) {
        guard let job = activeJob, job.id == jobID, let handler = job.progressHandler else { return }
        // Throttle: scanimage reports after every 32 KB read; the UI needs at most ~200 updates per scan.
        guard fraction - job.lastReportedProgress >= 0.005 else { return }
        job.lastReportedProgress = fraction
        handler(min(fraction, 0.99)) // 1.0 is reported once the file has been written
    }

    // MARK: - Jobs and device lock

    private func beginJob(progress: (@MainActor (Double) -> Void)?) throws -> SANEJob {
        guard activeJob == nil else { throw ScanError("Scanner is busy") }
        let job = SANEJob(progressHandler: progress)
        activeJob = job
        return job
    }

    private func endJob(_ job: SANEJob) {
        if activeJob === job { activeJob = nil }
    }

    private func acquireDevice() async {
        if !deviceInUse {
            deviceInUse = true
            return
        }
        await withCheckedContinuation { deviceWaiters.append($0) }
    }

    private func releaseDevice() {
        if deviceWaiters.isEmpty {
            deviceInUse = false
        } else {
            deviceWaiters.removeFirst().resume() // hand the device straight to the next waiter
        }
    }

    // MARK: - Small helpers

    private func deviceName(for scanner: ScannerInfo) -> String {
        renamedDevices[scanner.id] ?? String(scanner.id.hasPrefix("sane:") ? scanner.id.dropFirst(5) : Substring(scanner.id))
    }

    /// "xerox_mfp:libusb:000:017" -> "xerox_mfp".
    private static func backend(of device: String) -> String {
        String(device.prefix { $0 != ":" })
    }

    /// The scanner name without our " (SANE)" suffix, for messages.
    private static func plainName(_ scanner: ScannerInfo) -> String {
        scanner.name.hasSuffix(" (SANE)") ? String(scanner.name.dropLast(7)) : scanner.name
    }

    private static func makeWorkFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyScan-SANE-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func fallbackDocumentName(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        return "\(trimmed.isEmpty ? "Scan" : trimmed) \(formatter.string(from: Date()))"
    }

    private static let notInstalledError =
        ScanError("SANE is not installed. Install it with Homebrew: brew install sane-backends")
}

// MARK: - Job

/// One preview or scan. Lives on the main actor; `cancel()` reaches the running scanimage via `process`.
@MainActor
private final class SANEJob {
    let id = UUID()
    let progressHandler: (@MainActor (Double) -> Void)?
    var process: SANEProcess?
    private(set) var isCancelled = false
    var lastReportedProgress = -1.0

    init(progressHandler: (@MainActor (Double) -> Void)?) {
        self.progressHandler = progressHandler
    }

    func cancel() {
        isCancelled = true
        process?.terminate()
    }

    func throwIfCancelled() throws {
        if isCancelled { throw ScanError.cancelled }
    }
}

// MARK: - Device profile

/// A device's options from `--help`, with fallbacks for anything the help text did not tell us.
struct SANEDeviceProfile {
    static let fallbackResolutions = [75, 100, 150, 200, 300, 600]
    static let fallbackGlass = CGSize(width: 21.6, height: 29.7)

    let options: SANEDeviceOptions
    let capabilities: ScannerCapabilities
    /// EasyScan mode -> backend mode name.
    private let modeNames: [ScanColorMode: String]

    init(options: SANEDeviceOptions) {
        self.options = options
        var names = SANEParsing.modeNames(from: options.modes)
        if names.isEmpty { names = [.color: "Color", .gray: "Gray", .blackWhite: "Lineart"] }
        modeNames = names
        let resolutions = options.resolutions.isEmpty ? Self.fallbackResolutions : options.resolutions
        let glass: CGSize
        if let width = options.maxWidth, let height = options.maxHeight {
            glass = CGSize(width: width / 10, height: height / 10)
        } else {
            glass = Self.fallbackGlass
        }
        capabilities = ScannerCapabilities(resolutions: resolutions,
                                           modes: ScanColorMode.allCases.filter { names[$0] != nil },
                                           glassSize: glass)
    }

    /// The backend's name for `mode`, or for the closest mode it has.
    func modeName(for mode: ScanColorMode) -> String {
        let preference: [ScanColorMode]
        switch mode {
        case .color: preference = [.color, .gray, .blackWhite]
        case .gray: preference = [.gray, .color, .blackWhite]
        case .blackWhite: preference = [.blackWhite, .gray, .color]
        }
        return preference.lazy.compactMap { modeNames[$0] }.first ?? "Color"
    }

    /// `dpi` if the device accepts it, otherwise the nearest supported resolution.
    func resolution(nearest dpi: Int) -> Int {
        if let range = options.resolutionRange, range.contains(dpi) { return dpi }
        return capabilities.resolutions.min { abs($0 - dpi) < abs($1 - dpi) } ?? dpi
    }

    /// Selects the flatbed explicitly when the device has several sources (EasyScan scans from the glass).
    var sourceArguments: [String] {
        guard options.sourceActive, options.sources.count > 1,
              let flatbed = options.sources.first(where: { $0.caseInsensitiveCompare("Flatbed") == .orderedSame }) else { return [] }
        return ["--source", flatbed]
    }

    /// scanimage geometry arguments for `area` (centimetres, top-left origin; nil = whole glass). When the backend
    /// has no millimetre geometry options, scans the whole glass and returns the area as a crop to apply afterwards.
    func geometry(for area: CGRect?) throws -> SANEScanGeometry {
        guard let maxWidth = options.maxWidth, let maxHeight = options.maxHeight else {
            return SANEScanGeometry(arguments: [], softwareCrop: area, sizeInMillimeters: nil)
        }
        let glass = CGRect(x: 0, y: 0, width: maxWidth, height: maxHeight)
        var rect = glass
        if let area {
            rect = CGRect(x: area.minX * 10, y: area.minY * 10, width: area.width * 10, height: area.height * 10)
                .standardized.intersection(glass)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
                throw ScanError("The selected scan area is outside the scanner glass or too small.")
            }
        }
        let left = min(rect.minX, options.maxLeft ?? maxWidth)
        let top = min(rect.minY, options.maxTop ?? maxHeight)
        let width = min(rect.width, maxWidth - left)
        let height = min(rect.height, maxHeight - top)
        let arguments = ["-l", SANEParsing.formatMillimeters(left), "-t", SANEParsing.formatMillimeters(top),
                         "-x", SANEParsing.formatMillimeters(width), "-y", SANEParsing.formatMillimeters(height)]
        return SANEScanGeometry(arguments: arguments, softwareCrop: nil,
                                sizeInMillimeters: CGSize(width: width, height: height))
    }
}

/// How to get the requested area out of scanimage.
struct SANEScanGeometry {
    /// -l/-t/-x/-y arguments (empty when the backend has no millimetre geometry).
    var arguments: [String]
    /// Area (cm, top-left origin) to cut out in software after scanning the whole glass, for such backends.
    var softwareCrop: CGRect?
    /// Size of the area requested from the backend.
    var sizeInMillimeters: CGSize?

    /// The pixel size the requested area has at `dpi`. Some backends deliver extra padding lines/columns beyond it
    /// (xerox_mfp: ~5 mm more page height, and black padding rows plus wider rows in Lineart), which are trimmed.
    func expectedPixels(dpi: Int) -> SANEImageIO.PixelSize? {
        guard let size = sizeInMillimeters else { return nil }
        let perMillimeter = Double(dpi) / 25.4
        return SANEImageIO.PixelSize(width: max(1, Int((size.width * perMillimeter).rounded())),
                                     height: max(1, Int((size.height * perMillimeter).rounded())))
    }
}
