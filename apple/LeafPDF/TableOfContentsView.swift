import SwiftUI

/// The Table of Contents as a list: titles with printed page numbers at the
/// trailing edge, Sections nested under their Chapter or Section and folded
/// with the native disclosure control. Choosing an entry with a target calls
/// `onChoose` and dismisses the presentation it is in.
struct TableOfContentsView: View {
    let contents: TableOfContents
    let onChoose: (Place) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(contents.chapters, children: \.disclosedSections) { entry in
                Button {
                    guard let place = entry.place else { return }
                    dismiss()
                    onChoose(place)
                } label: {
                    HStack {
                        Text(entry.title)
                        Spacer()
                        Text(entry.pageNumber).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.place == nil)
            }
            .navigationTitle("Table of Contents")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 400, idealHeight: 520)
    }
}

extension TableOfContents.Entry {
    /// `List(children:)` wants nil, not empty, for entries without Sections.
    fileprivate var disclosedSections: [Self]? { sections.isEmpty ? nil : sections }
}
