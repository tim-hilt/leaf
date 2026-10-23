import SwiftUI

extension Binding where Value == Bool {
    /// Whether `item` is set, for presenting an alert or dialog about it;
    /// setting false (dismissing) clears it.
    init<Item>(isPresenting item: Binding<Item?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}
