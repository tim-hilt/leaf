import SwiftUI

/// The Table of Contents as a list: titles with printed page numbers, where
/// entries have them, at the trailing edge, Sections nested under their Chapter or Section and folded
/// with the native disclosure control. Choosing an entry with a target calls
/// `onChoose` and dismisses the presentation it is in.
///
/// With a `position`, its current entry is bold, the entries containing it are
/// unfolded and the list opens scrolled to it.
struct TableOfContentsView: View {
    let contents: TableOfContents
    let position: TableOfContents.Position?
    let onChoose: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Ids of the unfolded entries.
    @State private var unfolded: Set<Int>

    init(contents: TableOfContents, position: TableOfContents.Position?, onChoose: @escaping (Place) -> Void) {
        self.contents = contents
        self.position = position
        self.onChoose = onChoose
        _unfolded = State(initialValue: Set(position?.containing.map(\.id) ?? []))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                List {
                    ForEach(contents.chapters) { entry in
                        Row(entry: entry, currentID: position?.current.id, unfolded: $unfolded, choose: choose)
                    }
                }
                .task {
                    if let current = position?.current { scroller.scrollTo(current.id, anchor: .center) }
                }
            }
            .navigationTitle("Table of Contents")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 400, idealHeight: 520)
    }

    private func choose(_ place: Place) {
        dismiss()
        onChoose(place)
    }

    /// An entry and, in a disclosure group, its Sections.
    private struct Row: View {
        let entry: TableOfContents.Entry
        let currentID: Int?
        @Binding var unfolded: Set<Int>
        let choose: (Place) -> Void

        var body: some View {
            Group {
                if entry.sections.isEmpty {
                    label
                } else {
                    DisclosureGroup(isExpanded: isUnfolded) {
                        ForEach(entry.sections) { section in
                            Row(entry: section, currentID: currentID, unfolded: $unfolded, choose: choose)
                        }
                    } label: {
                        label
                    }
                }
            }
            .id(entry.id)
        }

        private var isUnfolded: Binding<Bool> {
            Binding(
                get: { unfolded.contains(entry.id) },
                set: { if $0 { unfolded.insert(entry.id) } else { unfolded.remove(entry.id) } })
        }

        private var label: some View {
            Button {
                if let place = entry.place { choose(place) }
            } label: {
                HStack {
                    Text(entry.title).fontWeight(entry.id == currentID ? .bold : .regular)
                    Spacer()
                    if let pageNumber = entry.pageNumber {
                        Text(pageNumber).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.place == nil)
        }
    }
}
