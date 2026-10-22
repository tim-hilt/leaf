import LeafCore

/// Where Back returns to, and where the Document Search session started, kept
/// for a document view, whatever its Format. The view passes the top of the
/// viewport in and moves the viewport itself; compare `backPlace` before and
/// after a change to report it.
struct JumpHistory: Equatable {
    /// The top of the viewport before the latest Jump; nil before any and after Back.
    private(set) var backPlace: Place?
    /// Where the current Document Search session started; nil outside a session.
    private var searchStart: Place?

    init(backPlace: Place? = nil) { self.backPlace = backPlace }

    /// Jump: remembers `top` as the Back place in place of any earlier one.
    /// Returns false, changing nothing, if `place` is already at `top` or there is no top.
    mutating func jump(to place: Place, from top: Place?) -> Bool {
        guard let top, !place.isSameSpot(as: top) else { return false }
        backPlace = top
        return true
    }

    /// Back: the Back place, which is forgotten; nil without one.
    mutating func goBack() -> Place? {
        defer { backPlace = nil }
        return backPlace
    }

    /// Starts a Document Search session at `top`. Until `endSearchSession()`, every
    /// `didReveal()` makes `top` the Back place, so the session is one Jump: Back
    /// returns to where the search started, also after an earlier Back.
    mutating func beginSearchSession(at top: Place?) { searchStart = top }

    /// Ends the session. The Back place it recorded stays.
    mutating func endSearchSession() { searchStart = nil }

    /// A Document Search match was revealed by moving the viewport.
    mutating func didReveal() {
        if let searchStart { backPlace = searchStart }
    }
}
