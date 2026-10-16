// App entry point: one window, the menu bar commands, and the list of scanner engines.
import SwiftUI
import AppKit

/// The scanner engines EasyScan talks to. This is the one place to swap the mock for the real engines.
@MainActor
func makeEngines() -> [any ScannerEngine] {
    #if DEBUG
    // Debug builds can run against a synthetic scanner (screenshots, UI work without hardware).
    if ProcessInfo.processInfo.environment["EASYSCAN_MOCK"] != nil { return [MockEngine()] }
    #endif
    // Image Capture first (any scanner macOS can see), SANE as the fallback the controller starts lazily.
    return [ImageCaptureEngine(), SANEEngine()]
}

@main
struct EasyScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = ScanController(engines: makeEngines())

    var body: some Scene {
        Window("EasyScan", id: "main") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    if SelfTest.isRequested {
                        // `EasyScan --selftest`: headless end-to-end run against the real scanner, then exit.
                        Task { exit(await SelfTest.run(controller: controller)) }
                        return
                    }
                    (NSApp.delegate as? AppDelegate)?.controller = controller
                    controller.start()
                    #if DEBUG
                    if UIDemo.isRequested { Task { await UIDemo.run(controller) } }
                    #endif
                }
                .onDisappear { controller.stop() }
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands { ScanCommands(controller: controller) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: ScanController?

    func applicationWillTerminate(_ notification: Notification) {
        // Cancel a running scan and stop discovery so no scanimage child keeps the USB device busy after we quit.
        controller?.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare executable (swift run), macOS treats the process as a background tool.
        // Make it a regular app with a Dock icon and menu bar, and bring its window to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
