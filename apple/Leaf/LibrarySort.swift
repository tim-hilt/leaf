import Foundation
import LeafCore

/// How the Gallery orders its Documents, as chosen on this device. The default
/// is Date Imported, newest first. The core does the ordering (`Listing`).
struct LibrarySort: Equatable {
    enum Key: String {
        case dateImported
        case title
        case recentlyRead
    }

    var key: Key
    /// Flips the order of `key`: oldest Import first, Z–A, or longest unread first.
    var isReversed: Bool

    static let standard = LibrarySort(key: .dateImported, isReversed: false)

    /// This choice as the core takes it.
    var core: Sort {
        let key: SortKey =
            switch key {
            case .dateImported: .dateImported
            case .title: .title
            case .recentlyRead: .recentlyRead
            }
        return Sort(key: key, reversed: isReversed)
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
