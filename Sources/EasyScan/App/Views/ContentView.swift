// The single window: scanners and recent scans on the left, the preview in the middle,
// settings and the Scan button on the right, and a status line along the bottom.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    PreviewArea()
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    InspectorPanel()
                        .frame(width: 280)
                }
                Divider()
                StatusBar()
            }
            .navigationTitle("EasyScan")
            .navigationSubtitle(controller.selectedScanner?.name ?? "No scanner")
        }
    }
}
