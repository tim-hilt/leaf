/// An update that runs once at the end of the main loop's turn, however often it
/// is asked for during that turn, as `setNeedsLayout` does for layout: a burst of
/// changes is shown all at once.
@MainActor
final class CoalescedUpdate {
    private let update: @MainActor () -> Void
    private var isPending = false

    init(_ update: @escaping @MainActor () -> Void) { self.update = update }

    /// Runs the update at the end of this turn, unless it already will.
    func setNeeded() {
        guard !isPending else { return }
        isPending = true
        Task { @MainActor in
            isPending = false
            update()
        }
    }
}
