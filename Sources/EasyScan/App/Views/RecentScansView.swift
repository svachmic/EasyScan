// The "Recent Scans" sidebar section: thumbnails of saved files. Double-click opens a file,
// the context menu offers Open, Show in Finder and Remove from List, and rows can be dragged out.
import SwiftUI

struct RecentScansSection: View {
    @EnvironmentObject private var controller: ScanController

    var body: some View {
        Section {
            if controller.recentScans.isEmpty {
                Text("Your scans will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(controller.recentScans) { record in
                    RecentScanRow(record: record)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { controller.open(record) }
                        .contextMenu {
                            Button("Open") { controller.open(record) }
                            Button("Show in Finder") { controller.reveal(record) }
                            Divider()
                            Button("Remove from List") { controller.remove(record) }
                        }
                        .onDrag { NSItemProvider(contentsOf: record.url) ?? NSItemProvider() }
                }
            }
        } header: {
            HStack {
                Text("Recent Scans")
                Spacer()
                Button {
                    FinderActions.showFolder(controller.settings.destinationFolder)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show Scans Folder")
                .accessibilityLabel("Show Scans Folder")
            }
        }
    }
}

struct RecentScanRow: View {
    let record: ScanRecord

    var body: some View {
        HStack(spacing: 10) {
            ScanThumbnail(record: record)
                .frame(width: 30, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Re-render now and then so "2 minutes ago" stays true.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(UIText.scanDetail(record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help("\(UIText.abbreviatedPath(record.url))\nDouble-click to open")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-click to open")
    }
}

struct ScanThumbnail: View {
    let record: ScanRecord

    var body: some View {
        if let thumbnail = record.thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .background(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        } else {
            Image(systemName: record.format == .pdf ? "doc.richtext" : "photo")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
