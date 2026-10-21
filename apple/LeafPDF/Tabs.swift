import Foundation
import Observation

/// What a window shows: the Documents open as Tabs, in order, the active one,
/// and whether the Reader or the Gallery is showing. One per window, and the
/// only owner of that state; views render it and forward user actions.
///
/// Saved to this Device's user defaults on every change (never synced) and
/// restored at launch, without Documents that left the Library.
@MainActor @Observable
final class Tabs {
    /// The open Documents' ids, in strip order.
    private(set) var openIDs: [String] {
        didSet { defaults.set(openIDs, forKey: Self.openName) }
    }
    /// The Tab the Reader shows, or would show; nil exactly when no Tab is open.
    private(set) var activeID: String? {
        didSet { defaults.set(activeID, forKey: Self.activeName) }
    }
    /// Whether the Reader, rather than the Gallery, is showing. Never true without Tabs.
    private(set) var isShowingReader: Bool {
        didSet { defaults.set(isShowingReader, forKey: Self.showsReaderName) }
    }

    /// Whether the Reader is in Immersive Mode, which hides the Tab strip. Set by
    /// the Reader, which owns it; kept here because the strip outlives each Tab's Reader.
    var isImmersive = false

    /// Opens `documents` in this order: one that has a Tab keeps it, the rest
    /// are appended. The first becomes active and the Reader shows.
    func open(_ documents: [LibraryDocument]) {
        guard let first = documents.first else { return }
        for document in documents where !openIDs.contains(document.id) { openIDs.append(document.id) }
        activeID = first.id
        isShowingReader = true
    }

    /// Closes the Tab of `id`. The active one gives way to its right neighbour,
    /// else its left; with none left the Gallery shows. The Document stays in the Library.
    func close(_ id: String) {
        guard let index = openIDs.firstIndex(of: id) else { return }
        openIDs.remove(at: index)
        viewStates[id] = nil
        if id == activeID { activeID = openIDs.indices.contains(index) ? openIDs[index] : openIDs.last }
        if openIDs.isEmpty { isShowingReader = false }
    }

    /// Closes the active Tab; nothing in the Gallery, so ⌘W never closes the window.
    func closeActive() {
        guard isShowingReader, let activeID else { return }
        close(activeID)
    }

    /// Shows the Reader on the Tab of `id`; nothing if it has none.
    func select(_ id: String) {
        guard openIDs.contains(id) else { return }
        activeID = id
        isShowingReader = true
    }

    /// The next Tab, wrapping around. Like `selectPrevious` and `select(number:)`,
    /// it acts only while the Reader shows.
    func selectNext() { step(by: 1) }

    func selectPrevious() { step(by: -1) }

    /// The Tab at `number`, counted from 1; nothing if there is none.
    func select(number: Int) {
        guard isShowingReader, openIDs.indices.contains(number - 1) else { return }
        activeID = openIDs[number - 1]
    }

    /// Shows the Gallery; the Tabs stay open.
    func goToGallery() { isShowingReader = false }

    /// Shows the Reader on the active Tab, if there is one.
    func showReader() { isShowingReader = activeID != nil }

    /// Closes the Tabs whose Document isn't in `documents` any more (Removed
    /// here or on another Device), by the closing rules.
    func keep(onlyIn documents: [LibraryDocument]) {
        let kept = Set(documents.map(\.id))
        for id in openIDs where !kept.contains(id) { close(id) }
    }

    /// The view state stored for the Tab of `id`; nil for a new Tab and after relaunch.
    func viewState(of id: String) -> ReaderViewState? { viewStates[id] }

    /// Stores the view state of the Tab of `id`, for when it is shown again.
    /// Nothing if it has no Tab, e.g. when the Reader of a closed Tab disappears.
    func store(_ state: ReaderViewState, for id: String) {
        guard openIDs.contains(id) else { return }
        viewStates[id] = state
    }

    private func step(by offset: Int) {
        guard isShowingReader, let activeID, let index = openIDs.firstIndex(of: activeID) else { return }
        self.activeID = openIDs[(index + offset + openIDs.count) % openIDs.count]
    }

    /// Each Tab's place, zoom and Back place while it isn't active. In memory only;
    /// not observed, since nothing renders it.
    @ObservationIgnored private var viewStates: [String: ReaderViewState] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    private static let openName = "tabs.open"
    private static let activeName = "tabs.active"
    private static let showsReaderName = "tabs.showsReader"

    /// Restores the Tabs saved in `defaults`, keeping those whose Document is in `library`.
    init(defaults: UserDefaults, library: [LibraryDocument]) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.openName) ?? []
        let active = defaults.string(forKey: Self.activeName)
        openIDs = saved
        activeID = active.flatMap { saved.contains($0) ? $0 : nil } ?? saved.first
        isShowingReader = !saved.isEmpty && defaults.bool(forKey: Self.showsReaderName)
        keep(onlyIn: library)
    }
}
