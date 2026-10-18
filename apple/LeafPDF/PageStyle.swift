/// How a Document's pages look, independently of the Theme. Light Pages is the default.
enum PageStyle: String, CaseIterable, Identifiable {
    case light, dark, match

    var id: Self { self }

    var title: String {
        switch self {
        case .light: "Light Pages"
        case .dark: "Dark Pages"
        case .match: "Match Theme"
        }
    }
}
