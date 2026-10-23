import CoreGraphics
import LeafCore
import Testing

@testable import Leaf

@Suite struct PlaceTests {
    @Test func epubPlacesReadInSpineOrderThenByOffset() {
        let early = Place.epub(spineIndex: 1, offset: 500)
        let late = Place.epub(spineIndex: 2, offset: 0)
        #expect(early.isAtOrBefore(late))
        #expect(!late.isAtOrBefore(early))
        #expect(late.isAtOrAfter(early))
        #expect(Place.epub(spineIndex: 2, offset: 10).isAtOrAfter(late))
        #expect(!Place.epub(spineIndex: 2, offset: 10).isAtOrBefore(late))
    }

    @Test func epubPlacesAreTheSameSpotOnlyAtTheSameOffset() {
        let place = Place.epub(spineIndex: 3, offset: 42)
        #expect(place.isSameSpot(as: .epub(spineIndex: 3, offset: 42)))
        #expect(!place.isSameSpot(as: .epub(spineIndex: 3, offset: 43)))
        #expect(!place.isSameSpot(as: .epub(spineIndex: 4, offset: 42)))
    }

    @Test func pdfPlacesReadByPageThenDownThePage() {
        let top = Place.pdf(pageIndex: 1, point: CGPoint(x: 0, y: 700))
        let lower = Place.pdf(pageIndex: 1, point: CGPoint(x: 0, y: 300))
        #expect(top.isAtOrBefore(lower))
        #expect(!lower.isAtOrBefore(top))
        #expect(lower.isAtOrBefore(.pdf(pageIndex: 2, point: CGPoint(x: 0, y: 800))))
    }

    @Test func pdfPlacesLessThanAPointApartAreTheSameSpot() {
        let place = Place.pdf(pageIndex: 0, point: CGPoint(x: 0, y: 500))
        #expect(place.isSameSpot(as: .pdf(pageIndex: 0, point: CGPoint(x: 30, y: 499.5))))
        #expect(!place.isSameSpot(as: .pdf(pageIndex: 0, point: CGPoint(x: 0, y: 498))))
    }

    @Test func placesOfDifferentFormatsHaveNoOrder() {
        let pdf = Place.pdf(pageIndex: 0, point: .zero)
        let epub = Place.epub(spineIndex: 0, offset: 0)
        #expect(!pdf.isAtOrBefore(epub))
        #expect(!epub.isAtOrBefore(pdf))
        #expect(!pdf.isSameSpot(as: epub))
    }
}
