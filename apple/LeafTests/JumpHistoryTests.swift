import CoreGraphics
import LeafCore
import Testing

@testable import Leaf

@Suite struct JumpHistoryTests {
    private func pdf(_ page: Int, y: CGFloat = 700) -> Place { .pdf(pageIndex: page, point: CGPoint(x: 0, y: y)) }

    private func jumped(from top: Place, to place: Place) -> JumpHistory {
        var history = JumpHistory()
        _ = history.jump(to: place, from: top)
        return history
    }

    @Test func backStaysWhileReadingNearTheLanding() {
        var history = jumped(from: pdf(1), to: pdf(10))
        history.didScroll(to: pdf(10, y: 100))
        history.didScroll(to: pdf(11))
        #expect(history.backPlace == pdf(1))
    }

    @Test func backGoesOnceReadingMovesAPageAndMoreAway() {
        var history = jumped(from: pdf(1), to: pdf(10))
        history.didScroll(to: pdf(12))
        #expect(history.backPlace == nil)
    }

    @Test func backGoesWhenScrollingBackToWhereTheJumpStarted() {
        var history = jumped(from: pdf(1), to: pdf(10))
        history.didScroll(to: pdf(1))
        #expect(history.backPlace == nil)
    }

    @Test func epubBackGoesAfterLeavingTheChapterOrAScreenOfText() {
        let start = Place.epub(spineIndex: 0, offset: 0)
        var near = jumped(from: start, to: .epub(spineIndex: 3, offset: 100))
        near.didScroll(to: .epub(spineIndex: 3, offset: 900))
        #expect(near.backPlace == start)
        near.didScroll(to: .epub(spineIndex: 3, offset: 5000))
        #expect(near.backPlace == nil)
        var next = jumped(from: start, to: .epub(spineIndex: 3, offset: 100))
        next.didScroll(to: .epub(spineIndex: 4, offset: 0))
        #expect(next.backPlace == nil)
    }

    @Test func aSearchSessionKeepsBackWhileScrolling() {
        var history = JumpHistory()
        history.beginSearchSession(at: pdf(1))
        history.didReveal()
        history.didScroll(to: pdf(20))
        #expect(history.backPlace == pdf(1))
    }
}
