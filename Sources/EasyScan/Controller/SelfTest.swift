// Headless end-to-end check used by `EasyScan --selftest`: discover, preview, scan, report, exit.
// Lets the app be verified against real hardware without clicking through the UI.
import Foundation
import AppKit

@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    /// Returns the process exit code. Output goes to stdout.
    static func run(controller: ScanController) async -> Int32 {
        func log(_ s: String) { print("[selftest] \(s)"); fflush(stdout) }
        let folder: URL = {
            if let env = ProcessInfo.processInfo.environment["EASYSCAN_SELFTEST_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
            return FileManager.default.temporaryDirectory.appendingPathComponent("EasyScan-selftest", isDirectory: true)
        }()
        let savedSettings = controller.settings
        let savedAppend = controller.appendToLastPDF
        defer {
            controller.settings = savedSettings
            controller.appendToLastPDF = savedAppend
        }
        controller.start()
        log("waiting for a scanner (up to 25 s)…")
        for _ in 0..<50 {
            if controller.scanners.contains(where: { $0.engine != .mock }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let scanner = controller.scanners.first(where: { $0.engine != .mock }) ?? controller.scanners.first else {
            log("FAIL: no scanner found"); return 1
        }
        log("scanner: \(scanner.name) [\(scanner.transport), \(scanner.engine.rawValue)]")
        controller.selectedScanner = scanner
        for _ in 0..<60 where controller.capabilities == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
        guard let caps = controller.capabilities else { log("FAIL: no capabilities (\(controller.status))"); return 1 }
        log("capabilities: \(caps.resolutions) dpi, modes \(caps.modes.map(\.rawValue)), glass \(caps.glassSize.width)x\(caps.glassSize.height) cm")

        controller.settings.destinationFolder = folder
        controller.settings.namePrefix = "Selftest"
        controller.settings.area = nil

        await controller.preview()
        if let img = controller.previewImage { log("preview: \(img.width)x\(img.height) px") } else { log("FAIL: preview (\(controller.status))"); return 1 }

        controller.settings.mode = .color
        controller.settings.resolution = caps.resolutions.contains(150) ? 150 : (caps.resolutions.first ?? 150)
        controller.settings.format = .pdf
        controller.appendToLastPDF = false
        await controller.scan()
        guard case .finished(let pdf) = controller.status else { log("FAIL: color pdf scan (\(controller.status))"); return 1 }
        log("scan 1: \(pdf.path) (\(fileSize(pdf)) bytes)")

        controller.appendToLastPDF = true
        await controller.scan()
        guard case .finished(let pdf2) = controller.status, pdf2 == pdf, controller.recentScans.first?.pageCount == 2 else {
            log("FAIL: append page (\(controller.status), pages \(controller.recentScans.first?.pageCount ?? -1))"); return 1
        }
        log("scan 2 appended: now \(controller.recentScans.first?.pageCount ?? 0) pages, \(fileSize(pdf)) bytes")
        controller.appendToLastPDF = false

        controller.settings.mode = .gray
        controller.settings.format = .png
        controller.settings.area = CGRect(x: 0, y: 0, width: min(10, caps.glassSize.width), height: min(5, caps.glassSize.height))
        await controller.scan()
        guard case .finished(let png) = controller.status else { log("FAIL: gray png area scan (\(controller.status))"); return 1 }
        log("scan 3 (gray, 10x5 cm area): \(png.path) (\(fileSize(png)) bytes)")
        controller.settings.area = nil

        log("OK — \(controller.recentScans.count) records, thumbnails: \(controller.recentScans.map { $0.thumbnail != nil })")
        controller.stop()
        return 0
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
