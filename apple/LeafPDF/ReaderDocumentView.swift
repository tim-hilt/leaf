import CoreGraphics

/// What `ReaderView` and the window's commands ask of the view that shows a
/// Document, whatever its Format. Tabs, Back, the Table of Contents, the find
/// bar and the popovers depend on this and on `Place`, never on a Format.
@MainActor
protocol ReaderDocumentView: AnyObject {
    /// The content at the top of the viewport; nil until there is some.
    var topOfViewport: Place? { get }
    /// The place, zoom and Back place, to reopen from; nil until laid out.
    var viewState: ReaderViewState? { get }

    /// Jump: goes to `place`, remembering where the viewport was for `goBack()`.
    func jump(to place: Place)
    /// Back: returns to where the latest Jump started; nothing without one.
    func goBack()

    /// Zooms in or out, or back to fit-to-width, keeping the place.
    func zoomIn()
    func zoomOut()
    func zoomToFitWidth()

    /// Highlights the selection, if there is one.
    func highlightSelection()
    /// Shows the native find bar.
    func presentFind()
    #if os(macOS)
        func findNext()
        func findPrevious()
    #endif

    /// Where to attach the popover of `note`, in the view's coordinates with
    /// the origin at the top-left; nil if the note isn't shown.
    func popoverPoint(of note: PageNote) -> CGPoint?
}

/// Lets window-level commands (macOS menu) reach the Reader's document view.
@MainActor
final class ReaderHandle {
    weak var view: (any ReaderDocumentView)?
}

/// What the Reader reports about a document view, set as one value. Each
/// callback defaults to doing nothing.
struct ReaderCallbacks {
    /// Called on a single tap on the page (iOS only; macOS clicks never fire it).
    var onSingleTap: () -> Void = {}
    /// Called once, after the Document is first laid out and scrolled to its opening Place.
    var onOpen: () -> Void = {}
    /// Called whenever the viewport scrolls, however it was moved: often, so keep it cheap.
    var onScroll: () -> Void = {}
    /// Called with the anchor of the selection when the reader highlights it.
    var onHighlight: (HighlightAnchor) -> Void = { _ in }
    /// Called when the reader clicks or taps a Highlight (the newest, where they
    /// overlap) at a point, given in the view's coordinates with the origin at
    /// the top-left.
    var onHighlightTap: (Highlight, CGPoint) -> Void = { _, _ in }
    /// Called when the reader asks for a page Note at a Place.
    var onAddNote: (Place) -> Void = { _ in }
    /// Called when the reader clicks or taps the icon of a page Note, with the
    /// point as for `onHighlightTap`.
    var onPageNoteTap: (PageNote, CGPoint) -> Void = { _, _ in }
    /// Called when the reader changes the text size of EPUBs by zooming, with the new size (`TextSize`).
    var onTextSizeChange: (CGFloat) -> Void = { _ in }
    /// Called when the Back place appears, changes or goes; nil when there is none.
    var onBackChange: (BackTarget?) -> Void = { _ in }
}

/// How the Back capsule names the place it returns to: "Back to p. 42", or
/// "Back to <Chapter>" where there are no page numbers.
struct BackTarget: Equatable {
    /// As shown after "Back to ".
    let name: String
    /// As VoiceOver reads it after "Back to ".
    let spokenName: String

    /// The Chapter or Section called `title`, in a Format without page numbers.
    static func chapter(_ title: String) -> BackTarget {
        BackTarget(name: title, spokenName: title)
    }

    /// The beginning of a Document, before its first Chapter.
    static let beginning = BackTarget(name: "the beginning", spokenName: "the beginning")

    /// The page with printed page number `number`.
    static func page(_ number: String) -> BackTarget {
        BackTarget(name: "p. \(number)", spokenName: "page \(number)")
    }
}
