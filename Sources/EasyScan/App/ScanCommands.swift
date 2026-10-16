// Menu bar commands. Replaces File > New Window (single window app) and the unused print items.
import SwiftUI

struct ScanCommands: Commands {
    @ObservedObject var controller: ScanController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan") { Task { await controller.scan() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!controller.canStartJob)
            Button("Preview") { Task { await controller.preview() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!controller.canStartJob)
            Button("Stop") { controller.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!controller.status.isBusy)
            Divider()
            Button("Choose Destination Folder…") { controller.chooseDestinationFolder() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Show Scans Folder") { FinderActions.showFolder(controller.settings.destinationFolder) }
        }
        // EasyScan does not print; this also frees ⇧⌘P (Page Setup) for Preview.
        CommandGroup(replacing: .printItem) {}
    }
}
