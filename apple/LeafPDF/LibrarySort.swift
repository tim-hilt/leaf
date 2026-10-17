import Foundation

/// How the Gallery orders its Documents. The default is Date Imported, newest
/// first.
struct LibrarySort: Equatable {
    enum Key: String {
        /// The core's order: newest Import first.
        case dateImported
        /// A–Z by Title, Finder-like: "2" before "10", ignoring case and accents.
        case title
        /// Newest Last Read first; never-opened Documents follow in the core's order.
        case recentlyRead
    }

    var key: Key
    /// Flips the order of `key`: oldest Import first, Z–A, or longest unread first.
    var isReversed: Bool

    static let standard = LibrarySort(key: .dateImported, isReversed: false)

    /// `documents`, which must be in the core's order (newest Import first),
    /// in this order. Documents with equal Titles or Last Read keep that order.
    func ordered(_ documents: [LibraryDocument]) -> [LibraryDocument] {
        switch key {
        case .dateImported:
            return flipped(documents)
        case .title:
            return flipped(Self.stable(documents) { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        case .recentlyRead:
            // Reversing flips only the opened Documents: never-opened ones always trail.
            let opened = documents.filter { $0.lastRead != nil }
            let neverOpened = documents.filter { $0.lastRead == nil }
            return flipped(Self.stable(opened) { $0.lastRead! > $1.lastRead! }) + neverOpened
        }
    }

    private func flipped(_ documents: [LibraryDocument]) -> [LibraryDocument] {
        isReversed ? documents.reversed() : documents
    }

    /// `documents` sorted by `areInIncreasingOrder`; equal ones keep their order.
    private static func stable(
        _ documents: [LibraryDocument], by areInIncreasingOrder: (LibraryDocument, LibraryDocument) -> Bool
    ) -> [LibraryDocument] {
        documents.enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static let keyName = "gallery.sort.key"
    private static let reversedName = "gallery.sort.reversed"

    /// The choice saved in `defaults`, or `standard` if there is none.
    init(from defaults: UserDefaults) {
        key = defaults.string(forKey: Self.keyName).flatMap(Key.init) ?? Self.standard.key
        isReversed = defaults.bool(forKey: Self.reversedName)
    }

    init(key: Key, isReversed: Bool) {
        self.key = key
        self.isReversed = isReversed
    }

    func save(to defaults: UserDefaults) {
        defaults.set(key.rawValue, forKey: Self.keyName)
        defaults.set(isReversed, forKey: Self.reversedName)
    }
}
