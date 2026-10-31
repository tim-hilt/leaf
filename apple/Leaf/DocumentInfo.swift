import SwiftUI

/// What the Gallery's context menu and the Reader's cog popover tell about a
/// Document: Title, Author (if known), Filetype, File size, size of its
/// Markup and other stored data, and Date Imported, in that order. Sizes are
/// read from disk when made.
struct DocumentInfo {
    struct Row: Identifiable {
        let label: LocalizedStringResource
        let value: String
        var id: String { String(localized: label) }
    }

    let rows: [Row]

    init(_ document: LibraryDocument) {
        let (fileBytes, dataBytes) = Self.sizes(of: document)
        var rows = [Row(label: "Title", value: document.title)]
        if let author = document.author { rows.append(Row(label: "Author", value: author)) }
        rows += [
            Row(label: "Filetype", value: document.format == .pdf ? "PDF" : "EPUB"),
            Row(label: "File Size", value: fileBytes.formatted(.byteCount(style: .file))),
            Row(label: "Annotations and Data", value: dataBytes.formatted(.byteCount(style: .file))),
            Row(label: "Imported", value: document.imported.formatted(date: .abbreviated, time: .omitted)),
        ]
        self.rows = rows
    }

    /// The File's size, and that of everything else in the Document's folder
    /// (its states, Reading Progress, details), in bytes.
    static func sizes(of document: LibraryDocument) -> (file: Int64, data: Int64) {
        let folder = document.file.deletingLastPathComponent()
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
        var file: Int64 = 0
        var data: Int64 = 0
        for entry in entries {
            let size = Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if entry.lastPathComponent == document.fileName { file = size } else { data += size }
        }
        return (file, data)
    }
}

extension View {
    /// A context menu offering "Remove" and showing the Document's info. On
    /// iOS the info is the preview, as menu items there truncate and grey out;
    /// macOS shows no previews, so there it's lines in the menu.
    func documentContextMenu(_ document: LibraryDocument, remove: @escaping () -> Void) -> some View {
        #if os(macOS)
            contextMenu {
                DocumentInfoMenuItems(info: DocumentInfo(document))
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            }
        #else
            contextMenu {
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            } preview: {
                DocumentInfoList(info: DocumentInfo(document))
                    .padding()
                    .frame(width: 320)
            }
        #endif
    }
}

/// `DocumentInfo` as plain lines, for a menu.
private struct DocumentInfoMenuItems: View {
    let info: DocumentInfo

    var body: some View {
        ForEach(info.rows) { row in
            Text("\(String(localized: row.label)): \(row.value)")
        }
    }
}

/// `DocumentInfo` as label and value lines, for a popover.
struct DocumentInfoList: View {
    let info: DocumentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(info.rows) { row in
                LabeledContent(String(localized: row.label), value: row.value)
            }
        }
        .font(.callout)
    }
}
