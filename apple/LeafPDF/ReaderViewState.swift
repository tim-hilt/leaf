import CoreGraphics

/// What a Reader needs to reopen exactly as it was: the top of the viewport,
/// the zoom as a multiple of fit-to-width (so it survives a new width), and
/// the Back place. Never persisted.
struct ReaderViewState: Equatable {
    var place: Place
    var zoom: CGFloat = 1
    var backPlace: Place?
}
