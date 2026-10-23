import Foundation
import Testing

@testable import Leaf

@Suite struct NoteLinksTests {
    private func links(in note: String) -> [(text: String, url: URL)] {
        let shown = NoteLinks.attributed(note)
        return shown.runs.compactMap { run in
            run.link.map { (String(shown[run.range].characters), $0) }
        }
    }

    @Test func webLinksInANoteAreClickable() {
        let found = links(in: "see https://example.com/a?b=c and http://example.org.")

        #expect(found.map(\.url.absoluteString) == ["https://example.com/a?b=c", "http://example.org"])
        #expect(found.map(\.text) == ["https://example.com/a?b=c", "http://example.org"])
    }

    @Test func otherLinkTypesStayPlainText() {
        #expect(links(in: "mail me@example.com or ftp://example.com/file or tel:+4912345678").isEmpty)
    }

    @Test func theNoteTextIsShownUnchanged() {
        let note = "a https://example.com b\nsecond line"
        #expect(String(NoteLinks.attributed(note).characters) == note)
    }

    @Test func aNoteWithoutLinksHasNone() {
        #expect(links(in: "just a thought").isEmpty)
    }
}
