import Observation

/// The matches of the Document Search that is going on, as the results list
/// shows them, whatever the Format. The find bar's adapter fills it as matches
/// arrive, in reading order, and keeps the current match; the list reads it and
/// asks the adapter to go to a match the reader chose. Everything runs on the
/// main actor.
///
/// Matches are numbered from 0 in the order they arrive.
@MainActor @Observable
final class SearchResults {
    /// What the list shows of a match.
    struct Match {
        let excerpt: DocumentSearch.Excerpt
        /// The printed number of its page; nil in a Format without pages.
        let pageNumber: String?
        /// The Chapter or Section it is in; nil if the Document has no Table of
        /// Contents or the match is before its first entry.
        let section: TableOfContents.Entry?

        init(_ match: DocumentSearch.Match) {
            excerpt = match.excerpt
            pageNumber = match.pageNumber
            section = match.section
        }

        init(_ match: EPUBSearch.Match) {
            excerpt = match.excerpt
            pageNumber = nil
            section = match.section
        }
    }

    /// Consecutive matches in the same Chapter or Section.
    struct Group: Identifiable {
        /// Number of its first match.
        let id: Int
        /// Title of the Chapter or Section; nil for matches outside any.
        let title: String?
        /// Numbers of its matches.
        fileprivate(set) var matches: Range<Int>
        fileprivate let sectionID: Int?
    }

    private(set) var matches: [Match] = []
    /// `matches` in groups, in order. A Document without a Table of Contents
    /// has a single, untitled group.
    private(set) var groups: [Group] = []
    /// Number of the current match, if any; the find bar's adapter keeps it.
    var current: Int?
    /// Whether the find bar is showing.
    var isFindBarOpen = false

    /// Goes to the match with the given number and makes it current. Set by
    /// the adapter of the find bar; does nothing until then.
    @ObservationIgnored var onChoose: (Int) -> Void = { _ in }

    /// Whether there is anything to list while the find bar is open.
    var isListable: Bool { isFindBarOpen && !matches.isEmpty }

    /// Adds the next match, found after the ones before it.
    func append(_ match: Match) {
        let number = matches.count
        matches.append(match)
        let sectionID = match.section?.id
        if let last = groups.last, last.sectionID == sectionID {
            groups[groups.count - 1].matches = last.matches.lowerBound..<number + 1
        } else {
            groups.append(
                Group(id: number, title: match.section?.title, matches: number..<number + 1, sectionID: sectionID))
        }
    }

    /// Forgets every match, as when a new search starts or the find bar closes.
    func removeAll() {
        matches = []
        groups = []
        current = nil
    }
}
