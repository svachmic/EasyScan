// Debug builds only: a scripted walk through the main UI states so the layout and the menu
// commands can be checked from a terminal, without clicking.
//
//   EASYSCAN_UI_DEMO=1 [EASYSCAN_UI_DEMO_APPEARANCE=light|dark] [EASYSCAN_UI_DEMO_SIZE=760x520] .build/debug/EasyScan
//
// Output on stdout, one line each:
//   MENU <moment>: <menu> > <item> [<modifier mask>+<key>] (disabled)   the menu bar at launch, mid-scan and after
//   KEY <shortcut> handled=<bool>                                       Preview and Scan fired through the menu bar
//   WINDOW <number>                                                     for `screencapture -l <number>`
//   SNAP <state>                                                        the state is now on screen and held for 1.5 s
//   DONE                                                                settings restored; the process can be killed
// Scans go to a temporary folder. The settings in use before the demo are restored before DONE.
#if DEBUG
import AppKit

@MainActor
enum UIDemo {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["EASYSCAN_UI_DEMO"] != nil }

    static func run(_ controller: ScanController) async {
        let environment = ProcessInfo.processInfo.environment
        switch environment["EASYSCAN_UI_DEMO_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let savedSettings = controller.settings
        let savedAppend = controller.appendToLastPDF
        controller.settings.destinationFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyScan-ui-demo", isDirectory: true)
        controller.settings.area = nil
        controller.settings.format = .pdf
        controller.appendToLastPDF = false

        await hold(1.0)
        if let size = environment["EASYSCAN_UI_DEMO_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window?.setContentSize(NSSize(width: size[0], height: size[1]))
            await hold(0.5)
        }
        printMenus("launch")
        print("WINDOW \(window?.windowNumber ?? 0)")
        await snap("empty")

        print("KEY shift-cmd-P handled=\(pressShortcut("p", [.command, .shift]))")
        await hold(0.3)
        await snap("previewing")
        await waitUntilIdle(controller)
        await snap("preview")

        controller.settings.area = CGRect(x: 3, y: 4, width: 12, height: 6)
        await snap("area")

        print("KEY cmd-R handled=\(pressShortcut("r", .command))")
        await hold(0.6)
        printMenus("scanning")
        await snap("scanning")
        await waitUntilIdle(controller)
        printMenus("finished")
        await snap("finished")

        controller.appendToLastPDF = true
        await controller.scan()
        await snap("appended")

        controller.appendToLastPDF = false
        controller.settings.destinationFolder = URL(fileURLWithPath: "/dev/null/EasyScan")
        await controller.scan()
        await snap("failed")
        controller.clearError()

        controller.stop()
        await hold(3.0)
        await snap("noscanner")
        controller.start()

        controller.settings = savedSettings
        controller.appendToLastPDF = savedAppend
        await hold(1.0)  // let UserDefaults persist the restored settings before anyone kills the process
        print("DONE")
        fflush(stdout)
    }

    private static var window: NSWindow? { NSApp.windows.first { $0.isVisible } }

    /// Lists the menu bar. SwiftUI refreshes menu items when a menu is about to open, so do that first.
    private static func printMenus(_ moment: String) {
        for menu in NSApp.mainMenu?.items ?? [] {
            guard let submenu = menu.submenu else { continue }
            submenu.delegate?.menuNeedsUpdate?(submenu)
            submenu.update()
            for item in submenu.items where !item.isSeparatorItem {
                let keys = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)]"
                print("MENU \(moment): \(menu.title) > \(item.title)\(keys)\(item.isEnabled ? "" : " (disabled)")")
            }
        }
        fflush(stdout)
    }

    /// Sends a key equivalent to the menu bar, as pressing it would.
    private static func pressShortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: 0) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private static func waitUntilIdle(_ controller: ScanController) async {
        await hold(0.1)
        for _ in 0..<100 where controller.status.isBusy { await hold(0.1) }
    }

    private static func snap(_ name: String) async {
        print("SNAP \(name)")
        fflush(stdout)
        await hold(1.5)
    }

    private static func hold(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
#endif
