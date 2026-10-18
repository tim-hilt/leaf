import PDFKit

/// Document Search: finds text in a Document with PDFKit's asynchronous find,
/// delivering matches as they're found. One search runs at a time; starting
/// another cancels the one before it. Everything runs on the main actor.
///
/// PDFKit matches substrings only, so Starts With and Full Word are decided
/// here, on word boundaries in the page's text.
@MainActor
final class DocumentSearch {
    enum WordMatch {
        /// Anywhere, even inside a longer word.
        case contains
        /// At the start of a word.
        case startsWith
        /// A whole word, delimited on both sides.
        case fullWord
    }

    /// What to look for. The defaults are the system find bar's: case-insensitive, Contains.
    struct Query {
        let text: String
        let caseSensitive: Bool
        let wordMatch: WordMatch

        init(_ text: String, caseSensitive: Bool = false, wordMatch: WordMatch = .contains) {
            self.text = text
            self.caseSensitive = caseSensitive
            self.wordMatch = wordMatch
        }
    }

    struct Match {
        let pageIndex: Int
        /// The matched text on its page, for highlighting.
        let selection: PDFSelection
    }

    private let document: PDFDocument
    private var running: Running?

    init(_ document: PDFDocument) { self.document = document }

    /// Searches for `query`, replacing any search still running. Calls
    /// `onMatch` for each match, in reading order, as it is found, then
    /// `onFinish` once nothing more will come. A cancelled search calls
    /// neither again. An empty query has no matches.
    func search(_ query: Query, onMatch: @escaping @MainActor (Match) -> Void, onFinish: @escaping @MainActor () -> Void) {
        cancel()
        guard !query.text.isEmpty else { return onFinish() }
        let running = Running(document: document, query: query)
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
    private let query: DocumentSearch.Query
    private var onMatch: (@MainActor (DocumentSearch.Match) -> Void)?
    private var onFinish: (@MainActor () -> Void)?
    /// Text of the page last matched on; matches arrive page by page.
    private var cachedPage: (page: PDFPage, text: NSString)?

    init(document: PDFDocument, query: DocumentSearch.Query) {
        self.document = document
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
        let index = document.index(for: page)
        if query.wordMatch != .contains {
            let text = text(of: page)
            let range = selection.range(at: 0, on: page)
            guard range.location != NSNotFound, NSMaxRange(range) <= text.length,
                !isWordCharacter(before: range.location, in: text)
            else { return nil }
            if query.wordMatch == .fullWord, isWordCharacter(at: NSMaxRange(range), in: text) { return nil }
        }
        return DocumentSearch.Match(pageIndex: index, selection: selection)
    }

    private func text(of page: PDFPage) -> NSString {
        if let cachedPage, cachedPage.page === page { return cachedPage.text }
        let text = (page.string ?? "") as NSString
        cachedPage = (page, text)
        return text
    }

    private func isWordCharacter(before index: Int, in text: NSString) -> Bool {
        index > 0 && isWordCharacter(at: index - 1, in: text)
    }

    /// Whether the character at UTF-16 offset `index` is a letter or digit;
    /// false past either end of the text.
    private func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length else { return false }
        let character = text.substring(with: text.rangeOfComposedCharacterSequence(at: index)).first
        return character.map { $0.isLetter || $0.isNumber } ?? false
    }
}
