import UniformTypeIdentifiers

/// The file types LeafPDF Imports: the "+" picker and Gallery drops accept
/// them, and `project.yml` declares them as document types. Add MOBI here and
/// there.
enum ImportableTypes {
    static let all: [UTType] = [.pdf, .epub]
}
