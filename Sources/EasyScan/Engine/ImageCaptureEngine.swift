// Scanner engine backed by Apple's ImageCaptureCore, the framework behind the Image Capture app.
//
// ImageCaptureCore is delegate based: you ask for something (open a session, select a functional unit, scan) and the
// answer arrives later in a delegate callback. This engine bridges those callbacks to async/await with one-shot
// continuations (`Pending`) that can only be resumed once and always carry a timeout, so a scanner that goes silent
// turns into a clear error instead of a hung UI.
//
// Life cycle of a scanner:
//   ICDeviceBrowser finds it  -> `DeviceEntry` is created and published in `scanners`.
//   First use                 -> requestOpenSession, wait for didOpenSession AND deviceDidBecomeReady.
//   While in use              -> the session stays open between previews and scans (opening one takes seconds).
//   Idle for a few minutes, stopDiscovery, or unplugged -> the session is closed so other apps can use the scanner.
import Foundation
import CoreGraphics
import ImageIO
import ImageCaptureCore
import os

private let iccLog = Logger(subsystem: "EasyScan", category: "ImageCapture")
/// Set EASYSCAN_DEBUG=1 to mirror the engine log to stderr (handy for command-line harnesses).
private let iccMirrorLogToStderr = ProcessInfo.processInfo.environment["EASYSCAN_DEBUG"] != nil

private func iccDebug(_ message: String) {
    iccLog.debug("\(message, privacy: .public)")
    if iccMirrorLogToStderr { FileHandle.standardError.write(Data("[icc] \(message)\n".utf8)) }
}

private func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(max(seconds, 0) * 1_000_000_000) }

@MainActor
final class ImageCaptureEngine: NSObject, ScannerEngine {
    let kind: EngineKind = .imageCapture
    private(set) var scanners: [ScannerInfo] = []
    var onScannersChanged: (([ScannerInfo]) -> Void)?

    private enum Timing {
        static let openSession: TimeInterval = 60
        static let selectUnit: TimeInterval = 30
        static let closeSession: TimeInterval = 10
        static let preview: TimeInterval = 5 * 60
        static let scan: TimeInterval = 15 * 60
        /// How long to wait for the driver to confirm a cancel before giving up on it.
        static let cancelGrace: TimeInterval = 20
        /// Requests sent too soon after `deviceDidBecomeReady` are silently dropped by the framework (see `settle`).
        static let settleAfterReady: TimeInterval = 1.0
        /// Quiet time after a scan completes before the next request. A request sent the moment the previous scan
        /// reports completion is "completed" instantly with no file; after a cancel the M2070 also needs to park its
        /// scan head and abort the file it was writing.
        static let quietAfterScan: TimeInterval = 1.0
        static let quietAfterCancel: TimeInterval = 3.0
        /// How long to wait for deviceDidBecomeReady after a successful open before assuming the device is ready.
        static let readyGrace: TimeInterval = 15
        static let progressPoll: TimeInterval = 0.5
        /// An open session blocks other apps (Image Capture, SANE, Preview), so close it after this much idle time.
        static let idleClose: TimeInterval = 60   // the Samsung driver allows one session; release it quickly so Image Capture can still be used * 60
    }

    /// Used when a driver reports no glass size. US Letter width by A4 height covers both paper sizes.
    private static let fallbackGlassSize = CGSize(width: 21.6, height: 29.7)
    private static let disconnectedError = ScanError("The scanner was disconnected.")

    /// Created on the first `startDiscovery` and never stopped; see `stopDiscovery`.
    private var browser: ICDeviceBrowser?
    /// Whether `scanners` is published. Devices are tracked even while discovery is stopped.
    private var isDiscovering = false
    private var entries: [String: DeviceEntry] = [:]
    /// Discovery order, so `scanners` keeps a stable order.
    private var order: [String] = []
    /// The single in-flight preview or scan. Only one runs at a time per engine.
    private var operation: Operation?

    // MARK: - ScannerEngine: discovery

    func startDiscovery() {
        isDiscovering = true
        guard browser == nil else {
            // Restarting: the browser kept tracking devices while discovery was stopped.
            publish()
            return
        }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        // The mask combines a device type with location types: USB, scanners shared by other Macs, Bonjour network
        // scanners and other remote ones.
        let mask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.remote.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
        self.browser = browser
        iccDebug("browser started")
        browser.start()
    }

    /// Closes every session and empties `scanners`, but deliberately leaves the ICDeviceBrowser running.
    /// ImageCaptureCore quirk (macOS 27, reproduced without this engine): once a browser has been stopped, any later
    /// `start()` in the same process, on a new or the same browser, makes the framework remove and re-add every device
    /// about once a second, indefinitely. A browser that is never stopped stays stable, so stop/start only toggles
    /// publishing here. A running browser costs nothing noticeable.
    func stopDiscovery() {
        guard isDiscovering else { return }
        isDiscovering = false
        if let op = operation {
            op.cancelRequested = true
            if op.requestIssued, let entry = entries[op.entryID] { entry.device.cancelScan() }
            op.waiting?.finish(.failure(ScanError.cancelled))
            op.done.finish(.failure(ScanError.cancelled))
        }
        for entry in entries.values {
            entry.failAllWaiters(with: ScanError.cancelled)
            entry.idleCloseTask?.cancel()
            if entry.session != .closed || entry.device.hasOpenSession { requestClose(entry) }
        }
        iccDebug("discovery stopped (browser kept running)")
        publish()
    }

    // MARK: - ScannerEngine: capabilities

    func capabilities(of scanner: ScannerInfo) async throws -> ScannerCapabilities {
        let entry = try entry(for: scanner)
        do {
            try await ensureSession(entry, for: nil)
            // Never switch functional units under a running preview or scan.
            if operation?.entryID != entry.id { try await selectFlatbedIfNeeded(entry, for: nil) }
            try checkpoint(nil, entry)
            let caps = Self.capabilities(of: entry.device.selectedFunctionalUnit)
            if operation?.entryID != entry.id { scheduleIdleClose(entry) }
            return caps
        } catch {
            if operation?.entryID != entry.id { scheduleIdleClose(entry) }
            throw Self.scanError(from: error, while: "Reading the scanner settings")
        }
    }

    // MARK: - ScannerEngine: preview

    func preview(_ scanner: ScannerInfo) async throws -> CGImage {
        let entry = try entry(for: scanner)
        let op = try begin(.preview, on: entry)
        defer { end(op) }
        do {
            try await prepare(entry, for: op)
            let device = entry.device
            let unit = device.selectedFunctionalUnit
            let lowest = Self.resolutions(of: unit).first ?? 75
            if !unit.canPerformOverviewScan {
                return try await previewByScanning(entry, op: op, resolution: lowest)
            }
            try Self.configure(unit, mode: .color, resolution: lowest, area: nil)
            unit.overviewResolution = lowest
            // Overview scans hand back an in-memory image, but point any stray file at a temporary folder anyway.
            device.transferMode = .fileBased
            device.downloadsDirectory = try Self.temporaryFolder()
            // A driver that "completes" an overview without scanning leaves the previous image in place.
            let previousOverview = unit.overviewImage
            _ = try await perform(op, on: entry, request: .overview, timeout: Timing.preview)
            try checkpoint(op, entry)
            guard let image = unit.overviewImage, image !== previousOverview else {
                throw ScanError("The scanner did not return a new preview image. Try again.")
            }
            return image
        } catch {
            throw finalError(error, for: op)
        }
    }

    /// Fallback for functional units without overview support: a normal low-resolution scan into a temporary file.
    private func previewByScanning(_ entry: DeviceEntry, op: Operation, resolution: Int) async throws -> CGImage {
        let device = entry.device
        try Self.configure(device.selectedFunctionalUnit, mode: .color, resolution: resolution, area: nil)
        device.transferMode = .fileBased
        device.downloadsDirectory = try Self.temporaryFolder()
        device.documentName = "EasyScan-preview-\(UUID().uuidString)"
        device.documentUTI = ScanFormat.png.uti
        guard let url = try await perform(op, on: entry, request: .scan, timeout: Timing.preview) else {
            throw ScanError("The scanner did not return a preview image.")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw ScanError("Could not read the preview image.")
        }
        return image
    }

    // MARK: - ScannerEngine: scan

    func scan(_ scanner: ScannerInfo, settings: ScanSettings, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let entry = try entry(for: scanner)
        let op = try begin(.scan, on: entry)
        defer { end(op) }
        do {
            try await prepare(entry, for: op)
            let device = entry.device
            let used = try Self.configure(device.selectedFunctionalUnit, mode: settings.mode,
                                          resolution: settings.resolution, area: settings.area)
            try FileManager.default.createDirectory(at: settings.destinationFolder, withIntermediateDirectories: true)
            let name = settings.documentName.isEmpty ? "Scan" : settings.documentName
            device.transferMode = .fileBased
            device.downloadsDirectory = settings.destinationFolder
            device.documentName = name
            device.documentUTI = settings.format.uti
            op.outputFolder = settings.destinationFolder
            op.documentName = name
            iccDebug("scan \(settings.mode.rawValue) \(used) dpi -> \(settings.destinationFolder.path)/\(name).\(settings.format.fileExtension)")
            progress(0)
            startProgressPolling(op, report: progress)
            let reported = try await perform(op, on: entry, request: .scan, timeout: Timing.scan)
            try checkpoint(op, entry)
            // didScanTo carries the real name; the framework appends a suffix when the file already exists.
            let expected = settings.destinationFolder.appendingPathComponent(name).appendingPathExtension(settings.format.fileExtension)
            guard let url = reported ?? (FileManager.default.fileExists(atPath: expected.path) ? expected : nil) else {
                throw ScanError("The scan finished, but the scanner did not deliver a file.")
            }
            op.progressTimer?.invalidate()
            progress(1)
            return Self.normalizedName(url, expected: expected)
        } catch {
            throw finalError(error, for: op)
        }
    }

    // MARK: - ScannerEngine: cancel

    func cancel() {
        guard let op = operation, !op.cancelRequested else { return }
        op.cancelRequested = true
        iccDebug("cancel requested")
        // Still waiting for the session or the flatbed: stop waiting right away.
        op.waiting?.finish(.failure(ScanError.cancelled))
        guard op.requestIssued, let entry = entries[op.entryID] else { return }
        // The driver confirms with didComplete(Overview)ScanWithError. Keep the engine busy until it does, so that late
        // callbacks of this scan cannot be mistaken for the next one, but do not wait forever.
        entry.device.cancelScan()
        op.cancelGraceTask = Task { @MainActor [weak op] in
            try? await Task.sleep(nanoseconds: nanoseconds(Timing.cancelGrace))
            guard !Task.isCancelled, let op else { return }
            iccDebug("driver did not confirm the cancel; giving up on it")
            entry.quietUntil = Date().addingTimeInterval(Timing.quietAfterCancel)
            op.done.finish(.failure(ScanError.cancelled))
        }
    }

    // MARK: - Operations

    private func entry(for scanner: ScannerInfo) throws -> DeviceEntry {
        guard isDiscovering, let entry = entries[scanner.id] else { throw Self.disconnectedError }
        return entry
    }

    private func begin(_ kind: Operation.Kind, on entry: DeviceEntry) throws -> Operation {
        guard operation == nil else { throw ScanError("Scanner is busy") }
        let op = Operation(kind: kind, entryID: entry.id)
        operation = op
        entry.idleCloseTask?.cancel()
        return op
    }

    private func end(_ op: Operation) {
        op.progressTimer?.invalidate()
        op.progressTimer = nil
        op.cancelGraceTask?.cancel()
        if operation === op { operation = nil }
        if let entry = entries[op.entryID] { scheduleIdleClose(entry) }
    }

    /// Opens the session if needed and makes sure the flatbed is selected.
    private func prepare(_ entry: DeviceEntry, for op: Operation) async throws {
        try await ensureSession(entry, for: op)
        try checkpoint(op, entry)
        try await selectFlatbedIfNeeded(entry, for: op)
        try checkpoint(op, entry)
    }

    /// Throws if the operation was cancelled, the scanner disappeared, or its session closed in the meantime.
    private func checkpoint(_ op: Operation?, _ entry: DeviceEntry) throws {
        if op?.cancelRequested == true { throw ScanError.cancelled }
        guard entries[entry.id] === entry else { throw Self.disconnectedError }
        guard entry.isUsable else { throw ScanError("The connection to the scanner was closed. Try again.") }
    }

    /// Issues a scan or overview request and waits for its completion callback. Returns the file URL, if any.
    private func perform(_ op: Operation, on entry: DeviceEntry, request: Operation.Request,
                         timeout: TimeInterval) async throws -> URL? {
        try await settle(entry)
        try checkpoint(op, entry)
        op.request = request
        op.progressBaseline = Double(entry.device.selectedFunctionalUnit.scanProgressPercentDone)
        op.requestIssued = true
        switch request {
        case .scan: entry.device.requestScan()
        case .overview: entry.device.requestOverviewScan()
        }
        let device = entry.device
        return try await op.done.wait(timeout: timeout) {
            device.cancelScan()
            return ScanError("The scanner did not finish within \(Int(timeout / 60)) minutes.", code: -9923)
        }
    }

    /// Maps any error to a ScanError. A cancelled operation always ends in `ScanError.cancelled`, and files it
    /// produced are removed.
    private func finalError(_ error: Error, for op: Operation) -> ScanError {
        Self.removeDriverTemporaryFiles(of: op)
        if op.cancelRequested {
            for url in op.scannedURLs { try? FileManager.default.removeItem(at: url) }
            return .cancelled
        }
        return Self.scanError(from: error, while: op.kind == .preview ? "The preview" : "The scan")
    }

    /// The driver writes into a hidden ".<name>.<ext>-XXXXXX" file and renames it when done. A cancelled or failed
    /// scan leaves that partial file behind in the user's folder, so remove it.
    private static func removeDriverTemporaryFiles(of op: Operation) {
        guard let folder = op.outputFolder, let name = op.documentName,
              let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for item in items where item.hasPrefix(".\(name).") && item.contains("-") {
            iccDebug("removing partial file \(item)")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(item))
        }
    }

    private func startProgressPolling(_ op: Operation, report: @escaping @MainActor (Double) -> Void) {
        // ImageCaptureCore has no progress callback for file based scans; poll the functional unit instead.
        let report = UncheckedBox(report)
        let timer = Timer(timeInterval: Timing.progressPoll, repeats: true) { [weak self, weak op] _ in
            // Scheduled on the main run loop, so this always runs on the main thread.
            MainActor.assumeIsolated {
                guard let self, let op, op.requestIssued, !op.cancelRequested, let entry = self.entries[op.entryID] else { return }
                let percent = Double(entry.device.selectedFunctionalUnit.scanProgressPercentDone)
                // The unit keeps reporting the previous scan's (or preview's) final value, often 100, until the new
                // scan really starts. Ignore readings until they move away from the value seen at request time.
                if let baseline = op.progressBaseline {
                    if abs(percent - baseline) < 0.5 { return }
                    op.progressBaseline = nil
                }
                let value = min(max(percent / 100, 0), 0.99)
                if value > op.lastProgress {
                    op.lastProgress = value
                    report.value(value)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        op.progressTimer = timer
    }

    // MARK: - Sessions

    /// Opens a session on the device and waits until it is ready. Several callers may wait for the same open.
    private func ensureSession(_ entry: DeviceEntry, for op: Operation?) async throws {
        entry.idleCloseTask?.cancel()
        if entry.isUsable { return }
        if entry.session == .closing { await waitUntilClosed(entry) }
        try ensureNotAbandoned(op, entry)

        let waiter = Pending<Void>()
        entry.openWaiters.append(waiter)
        op?.waiting = waiter
        defer {
            entry.openWaiters.removeAll { $0 === waiter }
            if op?.waiting === waiter { op?.waiting = nil }
        }
        if entry.session == .closed {
            entry.session = .opening
            entry.isReady = false
            requestOpen(entry)
        }
        try await waiter.wait(timeout: Timing.openSession) { [weak self] in
            let error = ScanError("The scanner did not respond within a minute. Check that it is switched on and connected, then try again.", code: -9923)
            // Fail everyone waiting for this open and reset, so the next attempt starts from scratch.
            entry.failOpenWaiters(with: error)
            self?.requestClose(entry)
            return error
        }
    }

    /// Like `checkpoint`, but does not require an open session.
    private func ensureNotAbandoned(_ op: Operation?, _ entry: DeviceEntry) throws {
        if op?.cancelRequested == true { throw ScanError.cancelled }
        guard entries[entry.id] === entry else { throw Self.disconnectedError }
    }

    /// Waits (briefly) for a close we requested earlier to finish before opening a new session.
    private func waitUntilClosed(_ entry: DeviceEntry) async {
        let waiter = Pending<Void>()
        entry.closeWaiters.append(waiter)
        defer { entry.closeWaiters.removeAll { $0 === waiter } }
        try? await waiter.wait(timeout: Timing.closeSession) { ScanError("Timed out closing the session") }
        if entry.session == .closing { entry.session = .closed }
    }

    /// Requests made inside the `deviceDidBecomeReady` callback, or right after it, are dropped by the framework with
    /// a "Scanner Device has not yet become ready" log line and no callback ever arrives. Waiting about a second
    /// after ready avoids that. It only costs time on the first request after opening a session.
    /// The same applies right after a scan completes (see `Timing.quietAfterScan`). Stale callbacks of the previous
    /// scan that arrive during this wait are ignored, because the new request has not been issued yet.
    private func settle(_ entry: DeviceEntry) async throws {
        var until = entry.readyAt.map { $0.addingTimeInterval(Timing.settleAfterReady) } ?? .distantPast
        if let quiet = entry.quietUntil, quiet > until { until = quiet }
        let remaining = until.timeIntervalSinceNow
        if remaining > 0 { try await Task.sleep(nanoseconds: nanoseconds(remaining)) }
    }

    /// Prefers the flatbed when the scanner also has a document feeder or transparency unit selected.
    private func selectFlatbedIfNeeded(_ entry: DeviceEntry, for op: Operation?) async throws {
        let device = entry.device
        let flatbed = ICScannerFunctionalUnitType.flatbed
        if device.selectedFunctionalUnit.type == flatbed { return }
        guard device.availableFunctionalUnitTypes.contains(where: { $0.uintValue == flatbed.rawValue }) else { return }
        try await settle(entry)
        try checkpoint(op, entry)

        let waiter = Pending<Void>()
        entry.selectWaiters.append(waiter)
        op?.waiting = waiter
        defer {
            entry.selectWaiters.removeAll { $0 === waiter }
            if op?.waiting === waiter { op?.waiting = nil }
        }
        if !entry.isSelecting {
            entry.isSelecting = true
            iccDebug("requestSelect flatbed (selected: \(device.selectedFunctionalUnit.type.rawValue))")
            device.requestSelect(flatbed)
        }
        try await waiter.wait(timeout: Timing.selectUnit) {
            entry.isSelecting = false
            return ScanError("The scanner did not switch to its flatbed.", code: -9929)
        }
    }

    /// Synchronous on purpose: inside an async function `requestOpenSession()` resolves to the newer async overload,
    /// which does not use the delegate flow this engine is built on.
    private func requestOpen(_ entry: DeviceEntry) {
        iccDebug("requestOpenSession \(entry.info.name)")
        entry.device.requestOpenSession()
    }

    private func requestClose(_ entry: DeviceEntry) {
        entry.idleCloseTask?.cancel()
        guard entry.session != .closing else { return }
        entry.readyGraceTask?.cancel()
        entry.session = .closing
        entry.isReady = false
        entry.readyAt = nil
        iccDebug("requestCloseSession \(entry.info.name)")
        entry.device.requestCloseSession()
    }

    /// deviceDidBecomeReady normally follows didOpenSession within a second or two. If a driver never sends it,
    /// carry on after a grace period instead of failing at the 60 s open timeout.
    private func scheduleReadyGrace(_ entry: DeviceEntry) {
        entry.readyGraceTask?.cancel()
        entry.readyGraceTask = Task { @MainActor [weak entry] in
            try? await Task.sleep(nanoseconds: nanoseconds(Timing.readyGrace))
            guard !Task.isCancelled, let entry, entry.session == .open, !entry.isReady else { return }
            iccDebug("no deviceDidBecomeReady after open; assuming ready")
            entry.markReady()
            entry.resumeOpenWaitersIfUsable()
        }
    }

    private func scheduleIdleClose(_ entry: DeviceEntry) {
        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = Task { @MainActor [weak self, weak entry] in
            try? await Task.sleep(nanoseconds: nanoseconds(Timing.idleClose))
            guard !Task.isCancelled, let self, let entry, self.entries[entry.id] === entry else { return }
            guard self.operation?.entryID != entry.id, entry.openWaiters.isEmpty, entry.selectWaiters.isEmpty,
                  entry.session == .open else { return }
            iccDebug("closing idle session")
            self.requestClose(entry)
        }
    }

    // MARK: - Delegate handlers (main actor)

    private func lookup(_ device: ICDevice) -> DeviceEntry? {
        entries.values.first { $0.device === device }
    }

    /// Publishes the device list (empty while discovery is stopped) and notifies only on actual changes.
    private func publish() {
        let list = isDiscovering ? order.compactMap { entries[$0]?.info } : []
        guard list != scanners else { return }
        scanners = list
        onScannersChanged?(list)
    }

    private func handleAdded(_ device: ICDevice) {
        guard let scanner = device as? ICScannerDevice, lookup(scanner) == nil else { return }
        let key = scanner.persistentIDString.nonEmpty ?? scanner.name.nonEmpty ?? scanner.uuidString.nonEmpty ?? UUID().uuidString
        var id = "icc:" + key
        if entries[id] != nil { id += "#" + (scanner.uuidString.nonEmpty ?? UUID().uuidString) }
        let info = ScannerInfo(id: id, name: scanner.name.nonEmpty ?? "Scanner",
                               transport: Self.transportName(for: scanner), engine: .imageCapture)
        scanner.delegate = self
        entries[id] = DeviceEntry(id: id, device: scanner, info: info)
        order.append(id)
        iccDebug("added \(info.name) [\(scanner.transportType ?? "?")] id=\(id)")
        publish()
    }

    private func handleRemoved(_ device: ICDevice) {
        guard let entry = lookup(device) else { return }
        iccDebug("removed \(entry.info.name)")
        if let op = operation, op.entryID == entry.id {
            op.waiting?.finish(.failure(Self.disconnectedError))
            op.done.finish(.failure(Self.disconnectedError))
        }
        entry.failAllWaiters(with: Self.disconnectedError)
        entry.idleCloseTask?.cancel()
        entry.device.delegate = nil
        entries[entry.id] = nil
        order.removeAll { $0 == entry.id }
        publish()
    }

    private func handleRenamed(_ device: ICDevice) {
        guard let entry = lookup(device), let name = device.name.nonEmpty, name != entry.info.name else { return }
        entry.info = ScannerInfo(id: entry.id, name: name, transport: entry.info.transport, engine: .imageCapture)
        publish()
    }

    private func handleSessionOpened(_ device: ICDevice, error: Error?) {
        guard let entry = lookup(device) else { return }
        guard entry.session == .opening || entry.session == .open else {
            // A late answer to an open we gave up on (timeout, cancel, stopDiscovery). If it did open, close it
            // again so the scanner is not held without anyone using it.
            if error == nil {
                iccDebug("late session open after giving up; closing it")
                entry.session = .open
                requestClose(entry)
            }
            return
        }
        if let ns = error as NSError?, !Self.isSessionAlreadyOpen(ns) {
            iccDebug("open session failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
            entry.session = .closed
            entry.isReady = false
            entry.failOpenWaiters(with: Self.scanError(from: ns, while: "Connecting to the scanner"))
            return
        }
        entry.session = .open
        if let ns = error as NSError? {
            // "Session already open": no ready callback follows, so treat the device as ready now.
            iccDebug("session was already open (\(ns.code)); continuing")
            entry.markReady()
        } else {
            iccDebug("session opened")
            if !entry.isReady { scheduleReadyGrace(entry) }
        }
        entry.resumeOpenWaitersIfUsable()
    }

    private func handleReady(_ device: ICDevice) {
        guard let entry = lookup(device) else { return }
        iccDebug("device ready")
        guard entry.session == .opening || entry.session == .open else { return }
        entry.session = .open
        entry.readyGraceTask?.cancel()
        entry.markReady()
        entry.resumeOpenWaitersIfUsable()
    }

    private func handleSessionClosed(_ device: ICDevice, error: Error?) {
        guard let entry = lookup(device) else { return }
        let previous = entry.session
        entry.session = .closed
        entry.isReady = false
        entry.readyAt = nil
        iccDebug("session closed (was \(previous))\(error.map { " error: \(($0 as NSError).code)" } ?? "")")
        entry.finishCloseWaiters()
        guard previous != .closing else { return }
        // We did not ask for this: the scanner was switched off, the driver quit or another app took over.
        let failure = ScanError("The scanner closed the connection unexpectedly. Try again.", code: (error as NSError?)?.code)
        entry.failOpenWaiters(with: failure)
        entry.isSelecting = false
        entry.selectWaiters.forEach { $0.finish(.failure(failure)) }
        if let op = operation, op.entryID == entry.id {
            op.waiting?.finish(.failure(failure))
            if op.requestIssued { op.done.finish(.failure(failure)) }
        }
    }

    private func handleFunctionalUnitSelected(_ scanner: ICScannerDevice, unit: ICScannerFunctionalUnit, error: Error?) {
        guard let entry = lookup(scanner) else { return }
        iccDebug("selected functional unit \(unit.type.rawValue)\(error.map { " error: \(($0 as NSError).code)" } ?? "")")
        entry.isSelecting = false
        // Give the device the same settling time as after ready before the next request.
        if entry.isReady { entry.readyAt = Date() }
        let result: Result<Void, Error> = error.map { .failure(Self.scanError(from: $0, while: "Selecting the flatbed")) } ?? .success(())
        let waiters = entry.selectWaiters
        waiters.forEach { $0.finish(result) }
    }

    /// Not fatal by itself, but remembered: when another process (SANE, a vendor tool) holds the USB interface, the
    /// driver reports a burst of -9933 here and then "completes" the scan without an error and without a file.
    private func handleDeviceError(_ device: ICDevice, error: NSError) {
        guard let entry = lookup(device), let op = operation, op.entryID == entry.id, op.requestIssued else { return }
        op.deviceErrors.append(error)
    }

    private func handleScanned(_ scanner: ICScannerDevice, url: URL) {
        iccDebug("didScanTo \(url.path)")
        guard let entry = lookup(scanner), let op = operation, op.entryID == entry.id else { return }
        op.scannedURLs.append(url)
    }

    private func handleCompleted(_ scanner: ICScannerDevice, request: Operation.Request, error: Error?) {
        iccDebug("completed \(request)\(error.map { " error: \(($0 as NSError).code) \($0.localizedDescription)" } ?? "")")
        guard let entry = lookup(scanner) else { return }
        // Also for stale completions: the device just finished something, give it a moment.
        let troubled = error != nil || operation?.cancelRequested == true
        entry.quietUntil = Date().addingTimeInterval(troubled ? Timing.quietAfterCancel : Timing.quietAfterScan)
        guard let op = operation, op.entryID == entry.id, op.requestIssued, op.request == request else { return }
        let deviceError = op.deviceErrors.last
        if let error {
            // A generic "could not complete" after communication errors: the communication error says more.
            let code = (error as NSError).code
            op.done.finish(.failure((code == -9930 || code == -9931) ? (deviceError ?? error) : error))
        } else if request == .scan, op.scannedURLs.isEmpty, !op.cancelRequested {
            op.done.finish(.failure(deviceError ?? ScanError("The scan finished, but the scanner did not deliver a file.")))
        } else {
            op.done.finish(.success(op.scannedURLs.last))
        }
    }

    // MARK: - Functional unit helpers

    private static func resolutions(of unit: ICScannerFunctionalUnit) -> [Int] {
        var list = Array(unit.supportedResolutions)
        if list.isEmpty { list = Array(unit.preferredResolutions) }
        if list.isEmpty, unit.nativeXResolution > 0 { list = [unit.nativeXResolution] }
        list = list.filter { $0 > 0 }.sorted()
        // A driver that reports a continuous range would flood the picker; fall back to its preferred list or
        // to the usual steps.
        if list.count > 12 {
            let preferred = Array(unit.preferredResolutions).filter { $0 > 0 }.sorted()
            if !preferred.isEmpty { return preferred }
            let standard = list.filter { [50, 75, 100, 150, 200, 240, 300, 400, 600, 1200, 2400, 4800].contains($0) }
            if !standard.isEmpty { return standard }
        }
        return list
    }

    private static func capabilities(of unit: ICScannerFunctionalUnit) -> ScannerCapabilities {
        let depths = unit.supportedBitDepths
        // ImageCaptureCore does not list supported pixel types, only bit depths. Drivers that do 8 bits per channel
        // offer RGB and gray; 1 bit means line art (black & white).
        var modes: [ScanColorMode] = []
        if depths.isEmpty || depths.contains(Int(ICScannerBitDepth.depth8Bits.rawValue))
            || depths.contains(Int(ICScannerBitDepth.depth16Bits.rawValue)) {
            modes += [.color, .gray]
        }
        if depths.contains(Int(ICScannerBitDepth.depth1Bit.rawValue)) { modes.append(.blackWhite) }
        let resolutions = resolutions(of: unit)
        return ScannerCapabilities(resolutions: resolutions.isEmpty ? [300] : resolutions,
                                   modes: modes, glassSize: glassSize(of: unit))
    }

    /// Centimeters per unit of the functional unit's current measurement unit.
    private static func centimetersPerUnit(_ unit: ICScannerFunctionalUnit) -> CGFloat {
        switch unit.measurementUnit {
        case .centimeters: return 1
        case .inches: return 2.54
        case .picas: return 2.54 / 6
        case .points: return 2.54 / 72
        case .twips: return 2.54 / 1440
        case .pixels: return 2.54 / CGFloat(max(unit.resolution, 1))
        @unknown default: return 1
        }
    }

    /// Glass size in centimeters. `physicalSize` and `scanArea` are expressed in `measurementUnit`, so switch it to
    /// centimeters first and convert from whatever the driver actually accepted.
    private static func glassSize(of unit: ICScannerFunctionalUnit) -> CGSize {
        unit.measurementUnit = .centimeters
        let factor = centimetersPerUnit(unit)
        let size = unit.physicalSize
        iccDebug("physicalSize \(size.width)x\(size.height) in unit \(unit.measurementUnit.rawValue)")
        guard size.width > 0, size.height > 0 else { return fallbackGlassSize }
        return CGSize(width: (size.width * factor * 100).rounded() / 100, height: (size.height * factor * 100).rounded() / 100)
    }

    /// Applies resolution, color mode and scan area (centimeters, origin top-left; nil = whole glass).
    /// Returns the resolution used, the supported one nearest to the requested one.
    @discardableResult
    private static func configure(_ unit: ICScannerFunctionalUnit, mode: ScanColorMode, resolution: Int, area: CGRect?) throws -> Int {
        let glass = CGRect(origin: .zero, size: glassSize(of: unit))
        let supported = resolutions(of: unit)
        let used = supported.min { abs($0 - resolution) < abs($1 - resolution) } ?? resolution
        unit.resolution = used
        switch mode {
        case .color:
            unit.pixelDataType = .RGB
            unit.bitDepth = .depth8Bits
        case .gray:
            unit.pixelDataType = .gray
            unit.bitDepth = .depth8Bits
        case .blackWhite:
            guard unit.supportedBitDepths.contains(Int(ICScannerBitDepth.depth1Bit.rawValue)) else {
                throw ScanError("This scanner cannot scan in black & white. Choose Grayscale instead.")
            }
            unit.pixelDataType = .BW
            unit.bitDepth = .depth1Bit
        }
        let requested = area ?? glass
        let clipped = requested.intersection(glass)
        guard !clipped.isNull, clipped.width >= 0.1, clipped.height >= 0.1 else {
            throw ScanError("The selected area is outside the scanner glass.")
        }
        let factor = centimetersPerUnit(unit)
        unit.scanArea = NSRect(x: clipped.minX / factor, y: clipped.minY / factor,
                               width: clipped.width / factor, height: clipped.height / factor)
        return used
    }

    /// The framework picks its own extension for some types (for example "jpg" for public.jpeg). When only the
    /// extension differs from `settings.outputURL`, rename the file so it lands exactly where the contract says.
    /// A name the framework made unique on purpose ("Scan 1.pdf") is kept.
    private static func normalizedName(_ url: URL, expected: URL) -> URL {
        guard url.standardizedFileURL != expected.standardizedFileURL,
              url.deletingPathExtension().lastPathComponent == expected.deletingPathExtension().lastPathComponent,
              url.deletingLastPathComponent().standardizedFileURL == expected.deletingLastPathComponent().standardizedFileURL,
              !FileManager.default.fileExists(atPath: expected.path) else { return url }
        do {
            try FileManager.default.moveItem(at: url, to: expected)
            return expected
        } catch {
            return url
        }
    }

    private static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EasyScan-ImageCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Naming and errors

    private static func transportName(for device: ICDevice) -> String {
        let location = device.type.rawValue
        let bonjour = location & ICDeviceLocationTypeMask.bonjour.rawValue != 0
        let shared = location & ICDeviceLocationTypeMask.shared.rawValue != 0
        guard let raw = device.transportType.nonEmpty else {
            if shared { return "Shared" }
            return bonjour || device.isRemote ? "Network" : "Unknown"
        }
        switch ICDeviceTransport(rawValue: raw) {
        case .transportTypeUSB: return "USB"
        case .transportTypeFireWire: return "FireWire"
        case .transportTypeBluetooth: return "Bluetooth"
        case .transportTypeMassStorage: return "Mass Storage"
        case .transportTypeTCPIP: return shared ? "Shared" : (bonjour ? "Network" : "TCP/IP")
        default:
            if shared { return "Shared" }
            if bonjour || device.isRemote { return "Network" }
            return raw.hasPrefix("ICTransportType") ? String(raw.dropFirst("ICTransportType".count)) : raw
        }
    }

    private static func isSessionAlreadyOpen(_ error: NSError) -> Bool {
        let code = errorCode(error)
        return code == -21347 /* ICReturnConnectionSessionAlreadyOpen */ || code == -9914 /* DeviceAlreadyOpenErr */
    }

    /// Drivers pass OSStatus values through as unsigned 32-bit numbers: the Samsung driver's "Too Many Clients"
    /// (-47, fBsyErr) arrives as 4294967249. Fold those back to the signed value.
    private static func errorCode(_ error: NSError) -> Int {
        let code = error.code
        if code > Int(Int32.max), code <= Int(UInt32.max) { return Int(Int32(truncatingIfNeeded: code)) }
        return code
    }

    /// Translates ImageCaptureCore error codes (ImageCaptureConstants.h) into messages for people.
    private static func scanError(from error: Error, while activity: String) -> ScanError {
        if let error = error as? ScanError { return error }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        let code = errorCode(ns)
        switch code {
        case -21345, -21344, -9927, -9901, -9915, -9917:
            return ScanError("Could not connect to the scanner. Check that it is switched on and plugged in.", code: code)
        case -21343:
            return ScanError("macOS did not allow EasyScan to use the scanner.", code: code)
        case -9923:
            return ScanError("The scanner did not respond in time. Check that it is switched on and try again.", code: code)
        case -9924:
            // "Scan operation canceled". Cancels we asked for never get here (see `finalError`), so someone else
            // stopped the scanner, typically another app taking it over.
            return ScanError("The scan was interrupted. The scanner may be in use by another app. Try again in a moment.", code: code)
        case -9933, -9932:
            // Unsolicited error from the scanner. On USB this is what another app holding the device looks like.
            return ScanError("The scanner is not responding. It may be in use by another app or still warming up. Try again in a moment.", code: code)
        case -9925, -9926, -21347, -9914, -47:
            // -47 (fBsyErr) is "Too Many Clients": the driver allows one session and another app holds it.
            return ScanError("The scanner is in use by another app or computer. Try again when it is free.", code: code)
        case -21350, -21349, -21348, -9900:
            return ScanError("The connection to the scanner was lost. Check the cable or network and try again.", code: code)
        case -9958, -9902, -9921:
            return ScanError("The connection to the scanner was closed. Try again.", code: code)
        case -9929:
            return ScanError("The scanner could not switch to its flatbed.", code: code)
        case -9930:
            return ScanError("The scanner could not finish the preview.", code: code)
        case -9931:
            return ScanError("The scanner could not finish the scan.", code: code)
        case -9953:
            return ScanError("The scanner asks for a user name and password, which EasyScan does not support yet.", code: code)
        case -9945, -9946, -9950:
            return ScanError("The software for this scanner is not installed. Install the manufacturer's driver and try again.", code: code)
        case -21100, -21099:
            return ScanError("Could not save the scan. Check that the destination folder exists and is writable.", code: code)
        default:
            return ScanError("\(activity) failed: \(ns.localizedDescription) (error \(code)).", code: code)
        }
    }
}

// MARK: - ImageCaptureCore delegates
//
// The protocols are not actor annotated. Callbacks arrive on the main thread in practice (the browser and sessions are
// created there), but nothing promises that, so every callback funnels through `onMain`.

extension ImageCaptureEngine: ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    nonisolated private func onMain(_ work: @escaping @Sendable @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            iccDebug("callback arrived off the main thread; hopping to main")
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let device = UncheckedBox(device)
        onMain { self.handleAdded(device.value) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let device = UncheckedBox(device)
        onMain { self.handleRemoved(device.value) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {
        let device = UncheckedBox(device)
        onMain { self.handleRenamed(device.value) }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        let device = UncheckedBox(device)
        onMain { self.handleRemoved(device.value) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        let box = UncheckedBox((device, error))
        onMain { self.handleSessionOpened(box.value.0, error: box.value.1) }
    }

    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        let device = UncheckedBox(device)
        onMain { self.handleReady(device.value) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        let box = UncheckedBox((device, error))
        onMain { self.handleSessionClosed(box.value.0, error: box.value.1) }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: Error?) {
        guard let ns = error as NSError? else { return }
        iccDebug("device error \(ns.code): \(ns.localizedDescription)")
        let box = UncheckedBox((device, ns))
        onMain { self.handleDeviceError(box.value.0, error: box.value.1) }
    }

    nonisolated func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {
        iccDebug("status \(status)")
    }

    nonisolated func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        iccDebug("scanner became available")
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        let box = UncheckedBox((scanner, functionalUnit, error))
        onMain { self.handleFunctionalUnitSelected(box.value.0, unit: box.value.1, error: box.value.2) }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        let scanner = UncheckedBox(scanner)
        onMain { self.handleScanned(scanner.value, url: url) }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) {
        let box = UncheckedBox((scanner, error))
        onMain { self.handleCompleted(box.value.0, request: .overview, error: box.value.1) }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        let box = UncheckedBox((scanner, error))
        onMain { self.handleCompleted(box.value.0, request: .scan, error: box.value.1) }
    }
}

// MARK: - State types

/// Carries framework objects from a delegate callback to the main actor. ImageCaptureCore objects are not Sendable,
/// but they are only touched on the main thread here.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A one-shot bridge from a delegate callback to async/await. `finish` may be called any number of times from any
/// path (callback, timeout, cancel, removal); only the first call resumes the waiter. A result that arrives before
/// anyone waits is kept for the waiter.
@MainActor
private final class Pending<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var earlyResult: Result<Value, Error>?
    private var isFinished = false

    func wait(timeout: TimeInterval, onTimeout: @escaping @MainActor () -> Error) async throws -> Value {
        if let result = earlyResult {
            earlyResult = nil
            return try result.get()
        }
        guard !isFinished else { throw ScanError("Internal error: operation already finished") }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            self.continuation = continuation
            // Strong capture on purpose: the timeout must fire even if nothing else references this object.
            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: nanoseconds(timeout))
                guard !Task.isCancelled, self.continuation != nil else { return }
                self.finish(.failure(onTimeout()))
            }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else {
            earlyResult = result
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class DeviceEntry {
    enum Session { case closed, opening, open, closing }

    let id: String
    let device: ICScannerDevice
    var info: ScannerInfo
    var session: Session = .closed
    var isReady = false
    /// When the device last became ready (or switched functional unit); see `ImageCaptureEngine.settle`.
    var readyAt: Date?
    /// No request before this time; set when a scan completes (see `ImageCaptureEngine.settle`).
    var quietUntil: Date?
    var isSelecting = false
    var openWaiters: [Pending<Void>] = []
    var selectWaiters: [Pending<Void>] = []
    var closeWaiters: [Pending<Void>] = []
    var idleCloseTask: Task<Void, Never>?
    var readyGraceTask: Task<Void, Never>?

    init(id: String, device: ICScannerDevice, info: ScannerInfo) {
        self.id = id
        self.device = device
        self.info = info
    }

    /// Open and ready: requests can be sent (after `settle`).
    var isUsable: Bool { session == .open && isReady }

    func markReady() {
        isReady = true
        readyAt = Date()
    }

    func resumeOpenWaitersIfUsable() {
        guard isUsable else { return }
        let waiters = openWaiters
        waiters.forEach { $0.finish(.success(())) }
    }

    func failOpenWaiters(with error: Error) {
        let waiters = openWaiters
        waiters.forEach { $0.finish(.failure(error)) }
    }

    func finishCloseWaiters() {
        let waiters = closeWaiters
        waiters.forEach { $0.finish(.success(())) }
    }

    func failAllWaiters(with error: Error) {
        let waiters = openWaiters + selectWaiters
        waiters.forEach { $0.finish(.failure(error)) }
        finishCloseWaiters()
        isSelecting = false
    }
}

@MainActor
private final class Operation {
    enum Kind { case preview, scan }
    enum Request { case overview, scan }

    let kind: Kind
    let entryID: String
    /// Completes with the scanned file URL (nil for overview scans) when the device reports completion.
    let done = Pending<URL?>()
    /// What the operation is waiting for before the device request (session open, flatbed selection).
    var waiting: Pending<Void>?
    var request: Request?
    var requestIssued = false
    var cancelRequested = false
    var scannedURLs: [URL] = []
    /// Where a file based scan writes, for cleaning up after a failed or cancelled scan.
    var outputFolder: URL?
    var documentName: String?
    /// Errors from `device(_:didEncounterError:)` while the request was running.
    var deviceErrors: [NSError] = []
    var lastProgress = 0.0
    /// `scanProgressPercentDone` when the request was issued; see `startProgressPolling`.
    var progressBaseline: Double?
    var progressTimer: Timer?
    var cancelGraceTask: Task<Void, Never>?

    init(kind: Kind, entryID: String) {
        self.kind = kind
        self.entryID = entryID
    }
}

private extension Optional where Wrapped == String {
    /// nil for nil and for empty strings.
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
