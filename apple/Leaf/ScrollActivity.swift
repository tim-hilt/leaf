import Observation

/// Whether the Gallery has been still long enough to render new Covers.
/// Feed it the scroll view's moving/idle changes; `isStill` is false while
/// scrolling and turns true again only after `quietPeriod` without movement,
/// so a flick that keeps going never triggers renders.
@MainActor @Observable
final class ScrollActivity {
    /// True from the start, so a Gallery that hasn't scrolled yet renders at once.
    private(set) var isStill = true
    @ObservationIgnored private let quietPeriod: Duration
    @ObservationIgnored private var settling: Task<Void, Never>?

    init(quietPeriod: Duration = .milliseconds(150)) { self.quietPeriod = quietPeriod }

    func scrollingChanged(isScrolling: Bool) {
        settling?.cancel()
        if isScrolling {
            isStill = false
            return
        }
        settling = Task {
            guard (try? await Task.sleep(for: quietPeriod)) != nil else { return }
            isStill = true
        }
    }
}
