// Right column: scan settings, where to save, and the Preview / Scan buttons.
import SwiftUI

struct InspectorPanel: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ScanSettingsSection()
                FileSettingsSection()
                DestinationSection()
            }
            .formStyle(.grouped)
            .disabled(controller.status.isBusy)

            Divider()
            ScanButtons()
                .padding(16)
        }
    }
}

/// Mode, resolution and area. The pickers only ever show values the selected scanner offers.
struct ScanSettingsSection: View {
    @EnvironmentObject private var controller: ScanController

    private var options: SettingsOptions { SettingsOptions(capabilities: controller.capabilities) }

    var body: some View {
        Section("Scan") {
            Picker("Mode", selection: modeSelection) {
                ForEach(options.modes) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Picker("Resolution", selection: resolutionSelection) {
                ForEach(options.resolutions, id: \.self) { dpi in
                    Text(UIText.dpi(dpi)).tag(dpi)
                }
            }
            .help("Higher resolution means more detail and bigger files. 300 dpi is good for documents.")
            LabeledContent("Area") {
                if let area = controller.settings.area {
                    HStack(spacing: 4) {
                        Text(UIText.area(area))
                            .monospacedDigit()
                        Button {
                            controller.settings.area = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Scan the whole page")
                        .accessibilityLabel("Clear area and scan the whole page")
                    }
                } else {
                    Text("Whole page")
                }
            }
        }
        .onChange(of: options, initial: true) { _, options in
            // The controller clamps settings when capabilities load. Before they load, the pickers show the fallback
            // lists; clamping to those would overwrite the saved preference (e.g. 1200 dpi) on every launch.
            guard controller.capabilities != nil else { return }
            let mode = options.validMode(controller.settings.mode)
            if mode != controller.settings.mode { controller.settings.mode = mode }
            let dpi = options.validResolution(controller.settings.resolution)
            if dpi != controller.settings.resolution { controller.settings.resolution = dpi }
        }
    }

    private var modeSelection: Binding<ScanColorMode> {
        Binding(get: { options.validMode(controller.settings.mode) },
                set: { controller.settings.mode = $0 })
    }

    private var resolutionSelection: Binding<Int> {
        Binding(get: { options.validResolution(controller.settings.resolution) },
                set: { controller.settings.resolution = $0 })
    }
}

/// Format and file name prefix.
struct FileSettingsSection: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        Section {
            Picker("Format", selection: $controller.settings.format) {
                ForEach(ScanFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            TextField("Name", text: $controller.settings.namePrefix, prompt: Text("Scan"))
                .help("Each file is named with this text plus the date and time")
        } header: {
            Text("File")
        } footer: {
            Text("Saved as “\(exampleName)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Mirrors the controller's naming ("<prefix> yyyy-MM-dd HH.mm.ss.<ext>") so the prefix field explains itself.
    private var exampleName: String {
        let prefix = controller.settings.namePrefix.trimmingCharacters(in: .whitespaces)
        let stamp = FileSettingsSection.stampFormatter.string(from: Date())
        return "\(prefix.isEmpty ? "Scan" : prefix) \(stamp).\(controller.settings.format.fileExtension)"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

/// Destination folder and "Append to last PDF".
struct DestinationSection: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        Section("Destination") {
            LabeledContent {
                Button("Choose…") { controller.chooseDestinationFolder() }
                    .help("Choose where scans are saved (⇧⌘D)")
            } label: {
                Label {
                    Text(controller.settings.destinationFolder.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
            }
            .help(UIText.abbreviatedPath(controller.settings.destinationFolder))
            .accessibilityLabel("Save to \(controller.settings.destinationFolder.lastPathComponent)")

            Toggle(isOn: appendBinding) {
                Text("Append to last PDF")
                Text(appendCaption)
            }
            .disabled(controller.appendTarget == nil)
        }
    }

    /// Shows off whenever appending is not possible, whatever the stored preference is.
    private var appendBinding: Binding<Bool> {
        Binding(get: { controller.appendToLastPDF && controller.appendTarget != nil },
                set: { controller.appendToLastPDF = $0 })
    }

    private var appendCaption: String {
        if let target = controller.appendTarget { return "Adds the next page to \(target.fileName)" }
        if controller.settings.format != .pdf { return "Available when the format is PDF." }
        return "Scan a PDF first, then add more pages to it."
    }
}

struct ScanButtons: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await controller.preview() }
            } label: {
                Label("Preview", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .help("Take a quick look at what is on the glass (⇧⌘P)")
            .accessibilityHint("Makes a quick low-resolution scan to show on screen")

            Button {
                Task { await controller.scan() }
            } label: {
                Label("Scan", systemImage: "doc.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .help("Scan and save with these settings (Return or ⌘R)")
            .accessibilityHint("Scans the page and saves it to the destination folder")
        }
        .controlSize(.large)
        .disabled(!controller.canStartJob)
    }
}
