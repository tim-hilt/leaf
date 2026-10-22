import PDFKit

/// Document Search: finds text in a Document with PDFKit's asynchronous find,
/// delivering matches as they're found. One search runs at a time; starting
/// another cancels the one before it. Everything runs on the main actor.
///
/// PDFKit matches substrings only, so Starts With, Ends With and Full Word are
/// decided here, on word boundaries in the page's text.
@MainActor
final class DocumentSearch {
    enum WordMatch {
        /// Anywhere, even inside a longer word.
        case contains
        /// At the start of a word.
        case startsWith
        /// At the end of a word.
        case endsWith
        /// A whole word, delimited on both sides.
        case fullWord
    }

    /// What to look for. The defaults are the system find bar's: case-insensitive, Contains.
    struct Query: Equatable {
        let text: String
        let caseSensitive: Bool
        let wordMatch: WordMatch

        init(_ text: String, caseSensitive: Bool = false, wordMatch: WordMatch = .contains) {
            self.text = text
            self.caseSensitive = caseSensitive
            self.wordMatch = wordMatch
        }
    }

    /// The text around a match, on one line, for telling matches apart in a list.
    struct Excerpt {
        let text: String
        /// Where the match is in `text`.
        let matchRange: Range<String.Index>
    }

    struct Match {
        let pageIndex: Int
        /// The matched text on its page, for highlighting.
        let selection: PDFSelection
        /// The match's range in its page's text, in UTF-16 units.
        let range: NSRange
        let excerpt: Excerpt
        /// The printed number of the page, or its position in the File if it has none.
        let pageNumber: String
        /// The Chapter or Section the match is in; nil if the Document has no
        /// Table of Contents or the match is before its first entry.
        let section: TableOfContents.Entry?
    }

    private let document: PDFDocument
    private let contents: TableOfContents
    private var running: Running?

    /// `contents` is the Document's Table of Contents, which places matches in
    /// Chapters and Sections.
    init(_ document: PDFDocument, contents: TableOfContents) {
        self.document = document
        self.contents = contents
    }

    /// Searches for `query`, replacing any search still running. Calls
    /// `onMatch` for each match, in reading order, as it is found, then
    /// `onFinish` once nothing more will come. A cancelled search calls
    /// neither again. An empty query has no matches.
    func search(
        _ query: Query, onMatch: @escaping @MainActor (Match) -> Void, onFinish: @escaping @MainActor () -> Void
    ) {
        cancel()
        guard !query.text.isEmpty else { return onFinish() }
        let running = Running(document: document, contents: contents, query: query)
        self.running = running
        running.start(onMatch: onMatch) { [weak self] in
            self?.running = nil
            onFinish()
        }
    }

    /// Stops the search that is running, if any.
    func cancel() {
        running?.stop()
        running = nil
    }
}

/// One search: its notification observers and the page text its word-boundary
/// checks read. PDFKit posts its notifications on the main thread.
@MainActor
private final class Running: NSObject {
    private let document: PDFDocument
    private let contents: TableOfContents
    private let query: DocumentSearch.Query
    private var onMatch: (@MainActor (DocumentSearch.Match) -> Void)?
    private var onFinish: (@MainActor () -> Void)?
    /// Text of the page last matched on; matches arrive page by page.
    private var cachedPage: (page: PDFPage, text: NSString)?

    init(document: PDFDocument, contents: TableOfContents, query: DocumentSearch.Query) {
        self.document = document
        self.contents = contents
        self.query = query
    }

    func start(
        onMatch: @escaping @MainActor (DocumentSearch.Match) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.onMatch = onMatch
        self.onFinish = onFinish
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didFindMatch), name: .PDFDocumentDidFindMatch, object: document)
        center.addObserver(self, selector: #selector(didEndFind), name: .PDFDocumentDidEndFind, object: document)
        document.beginFindString(query.text, withOptions: query.caseSensitive ? [] : [.caseInsensitive])
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        onMatch = nil
        onFinish = nil
        document.cancelFindString()
    }

    @objc private func didFindMatch(_ note: Notification) {
        guard let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
            let match = accept(selection)
        else { return }
        onMatch?(match)
    }

    @objc private func didEndFind(_ note: Notification) {
        let finish = onFinish
        stop()
        finish?()
    }

    /// The match for `selection`, unless it fails the query's word-match method.
    private func accept(_ selection: PDFSelection) -> DocumentSearch.Match? {
        guard let page = selection.pages.first else { return nil }
        let text = text(of: page)
        let range = selection.range(at: 0, on: page)
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        guard query.accepts(range, in: text) else { return nil }
        let index = document.index(for: page)
        let top = selection.bounds(for: page)
        return DocumentSearch.Match(
            pageIndex: index, selection: selection, range: range,
            excerpt: DocumentSearch.Excerpt(around: range, in: text),
            pageNumber: document.printedPageNumber(at: index),
            section: contents.position(at: Place.pdf(pageIndex: index, point: CGPoint(x: top.minX, y: top.maxY)))?
                .current)
    }

    private func text(of page: PDFPage) -> NSString {
        if let cachedPage, cachedPage.page === page { return cachedPage.text }
        let text = (page.string ?? "") as NSString
        cachedPage = (page, text)
        return text
    }

}

extension DocumentSearch.Query {
    /// Whether the text at `range` in `text` is a match as far as the word-match
    /// method goes: it starts and ends at word boundaries as asked.
    func accepts(_ range: NSRange, in text: NSString) -> Bool {
        let startsWord = !Self.isWordCharacter(at: range.location - 1, in: text)
        let endsWord = !Self.isWordCharacter(at: NSMaxRange(range), in: text)
        return switch wordMatch {
        case .contains: true
        case .startsWith: startsWord
        case .endsWith: endsWord
        case .fullWord: startsWord && endsWord
        }
    }

    /// Where the query is in `text`, in order and without overlap, keeping the
    /// occurrences `accepts`.
    func ranges(in text: NSString) -> [NSRange] {
        guard !self.text.isEmpty else { return [] }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var found: [NSRange] = []
        var from = 0
        while from < text.length {
            let range = text.range(
                of: self.text, options: options, range: NSRange(location: from, length: text.length - from))
            guard range.location != NSNotFound else { break }
            if accepts(range, in: text) { found.append(range) }
            from = NSMaxRange(range)
        }
        return found
    }

    /// Whether the character at UTF-16 offset `index` is a letter or digit;
    /// false past either end of the text.
    private static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length else { return false }
        let character = text.substring(with: text.rangeOfComposedCharacterSequence(at: index)).first
        return character.map { $0.isLetter || $0.isNumber } ?? false
    }
}

extension DocumentSearch.Excerpt {
    /// How much text is kept before and after the match, in UTF-16 units.
    private static let before = 40
    private static let after = 80

    /// The text around `range` in `text`, cut to a few words either side, with
    /// every run of white space (line breaks included) made one space.
    init(around range: NSRange, in text: NSString) {
        let start = max(0, range.location - Self.before)
        let end = min(text.length, NSMaxRange(range) + Self.after)
        // Never cut a character in two.
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        func slice(_ from: Int, _ to: Int) -> String {
            text.substring(with: NSRange(location: from, length: to - from)).replacing(/\s+/, with: " ")
        }
        let leading = String(slice(window.location, range.location).drop(while: \.isWhitespace))
        let matched = slice(range.location, NSMaxRange(range))
        var trailing = slice(NSMaxRange(range), NSMaxRange(window))
        while trailing.last?.isWhitespace == true { trailing.removeLast() }
        self.text = leading + matched + trailing
        let lower = self.text.index(self.text.startIndex, offsetBy: leading.count)
        matchRange = lower..<self.text.index(lower, offsetBy: matched.count)
    }
}
