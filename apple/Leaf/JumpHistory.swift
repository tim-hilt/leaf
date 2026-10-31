import LeafCore

/// Where Back returns to, and where the Document Search session started, kept
/// for a document view, whatever its Format. The view passes the top of the
/// viewport in and moves the viewport itself; compare `backPlace` before and
/// after a change to report it.
struct JumpHistory: Equatable {
    /// The top of the viewport before the latest Jump; nil before any and after Back.
    private(set) var backPlace: Place?
    /// Where the latest Jump landed, or the first place seen after opening or a
    /// Document Search reveal; nil until known. Moving far from it ends Back.
    private var landing: Place?
    /// Where the current Document Search session started; nil outside a session.
    private var searchStart: Place?

    /// Jump: remembers `top` as the Back place in place of any earlier one.
    /// Returns false, changing nothing, if `place` is already at `top` or there is no top.
    mutating func jump(to place: Place, from top: Place?) -> Bool {
        guard let top, !place.isSameSpot(as: top) else { return false }
        backPlace = top
        landing = place
        return true
    }

    /// Back: the Back place, which is forgotten; nil without one.
    mutating func goBack() -> Place? {
        defer {
            backPlace = nil
            landing = nil
        }
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
        if let searchStart {
            backPlace = searchStart
            landing = nil
        }
    }

    /// The viewport moved to `top`. Back is forgotten once the reader has moved
    /// on: back at the Back place, or about a page or more from where they
    /// landed. Does nothing during a Document Search session.
    mutating func didScroll(to top: Place) {
        guard let backPlace, searchStart == nil else { return }
        guard let landing else {
            landing = top
            return
        }
        if top.isSameSpot(as: backPlace) || top.isFar(from: landing) {
            self.backPlace = nil
            self.landing = nil
        }
    }
}
