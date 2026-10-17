import Foundation

/// How the Gallery orders its Documents. The default is Date Imported, newest
/// first.
struct LibrarySort: Equatable {
    enum Key: String {
        /// The core's order: newest Import first.
        case dateImported
        /// A–Z by Title, Finder-like: "2" before "10", ignoring case and accents.
        case title
    }

    var key: Key
    /// Flips the order of `key`: oldest Import first, or Z–A.
    var isReversed: Bool

    static let standard = LibrarySort(key: .dateImported, isReversed: false)

    /// `documents`, which must be in the core's order (newest Import first),
    /// in this order. Documents with equal Titles keep that order.
    func ordered(_ documents: [LibraryDocument]) -> [LibraryDocument] {
        var ordered = documents
        if key == .title {
            ordered = documents.enumerated().sorted { a, b in
                switch a.element.title.localizedStandardCompare(b.element.title) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: a.offset < b.offset
                }
            }.map(\.element)
        }
        return isReversed ? ordered.reversed() : ordered
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
