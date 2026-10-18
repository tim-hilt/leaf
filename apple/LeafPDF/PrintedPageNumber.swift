import PDFKit

extension PDFDocument {
    /// The number printed on the page at `index` (its page label, e.g. "xii"),
    /// or its 1-based position in the File when it has none.
    func printedPageNumber(at index: Int) -> String {
        page(at: index)?.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
    }
}
