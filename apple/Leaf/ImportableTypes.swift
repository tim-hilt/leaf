import UniformTypeIdentifiers

/// The file types Leaf Imports: the "+" picker and Gallery drops accept
/// them, and `project.yml` declares them as document types. Add MOBI here and
/// there.
enum ImportableTypes {
    static let all: [UTType] = [.pdf, .epub]
}
