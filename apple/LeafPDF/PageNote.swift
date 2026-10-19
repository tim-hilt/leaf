/// A Note on a spot of a page, belonging to no passage. It can't be moved.
struct PageNote: Identifiable, Equatable {
    let id: String
    let place: Place
    /// What the reader wrote. Empty only between adding the Note and typing.
    var text: String
}
