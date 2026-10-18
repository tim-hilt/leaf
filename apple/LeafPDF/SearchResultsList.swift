import SwiftUI

/// The matches of Document Search as a lazy native `List`: each row shows the
/// text around the match, the match in bold, and the printed page number at
/// the trailing edge. With a Table of Contents, rows are in sections per
/// Chapter or Section. The current match is selected, and choosing a row
/// asks `results` to go to it, then calls `didChoose`.
struct SearchResultsList: View {
    let results: SearchResults
    var didChoose: () -> Void = {}

    var body: some View {
        ScrollViewReader { scroller in
            List(selection: selection) {
                ForEach(results.groups) { group in
                    Section {
                        ForEach(group.matches, id: \.self) { number in
                            Row(match: results.matches[number])
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            #if os(macOS)
                .listStyle(.sidebar)
            #endif
            // Keeps the current match in view when the bar steps to another.
            .onChange(of: results.current) { _, current in
                if let current { scroller.scrollTo(current, anchor: .center) }
            }
            .task {
                if let current = results.current { scroller.scrollTo(current, anchor: .center) }
            }
        }
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { results.current },
            set: { number in
                guard let number else { return }
                results.onChoose(number)
                didChoose()
            })
    }

    private struct Row: View {
        let match: DocumentSearch.Match

        var body: some View {
            HStack {
                Text(match.excerpt.highlighted).lineLimit(2)
                Spacer()
                Text(match.pageNumber).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The list of matches in a full-height sheet, for compact widths. Choosing a
/// match closes it, so the page shows.
struct SearchResultsSheet: View {
    let results: SearchResults
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SearchResultsList(results: results, didChoose: dismiss.callAsFunction)
                .navigationTitle("Results")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismiss.callAsFunction) }
                }
        }
        .presentationDetents([.large])
    }
}

extension DocumentSearch.Excerpt {
    /// The excerpt with the match in bold.
    var highlighted: AttributedString {
        var string = AttributedString(text)
        if let range = Range(matchRange, in: string) { string[range].inlinePresentationIntent = .stronglyEmphasized }
        return string
    }
}
