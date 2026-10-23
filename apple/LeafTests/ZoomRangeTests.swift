import CoreGraphics
import Testing

@testable import Leaf

@Suite struct ZoomRangeTests {
    // Fit-to-width of a Document whose pages are drawn at 0.6× their natural size.
    let range = ZoomRange(fitToWidth: 0.6)

    @Test func cannotZoomOutPastFitToWidth() {
        #expect(range.clamped(0.2) == 0.6)
    }

    @Test func canZoomInToFiveTimesFitToWidth() {
        #expect(range.clamped(3.0) == 3.0)
    }

    @Test func cannotZoomInPastFiveTimesFitToWidth() {
        #expect(range.clamped(10) == 3.0)
    }

    @Test func leavesScalesWithinTheLimitsUntouched() {
        #expect(range.clamped(1.25) == 1.25)
    }

    @Test func doubleTapZoomsInFromFitToWidth() {
        #expect(range.doubleTapTarget(from: 0.6) == 1.2)
    }

    @Test func doubleTapZoomsBackOutToFitToWidthWhenZoomedIn() {
        #expect(range.doubleTapTarget(from: 1.8) == 0.6)
    }

    @Test func doubleTapTreatsRoundingNoiseAsFitToWidth() {
        #expect(range.doubleTapTarget(from: 0.6003) == 1.2)
    }

    // MARK: Keyboard zoom

    @Test func zoomInStepsUpFromFitToWidth() {
        #expect(range.zoomedIn(from: 0.6) == 0.75)
    }

    @Test func zoomInStopsAtFiveTimesFitToWidth() {
        #expect(range.zoomedIn(from: 2.8) == 3.0)
    }

    @Test func zoomOutStepsDown() {
        #expect(range.zoomedOut(from: 1.5) == 1.2)
    }

    @Test func zoomOutStopsAtFitToWidth() {
        #expect(range.zoomedOut(from: 0.7) == 0.6)
    }

    // MARK: Keeping your place when fit-to-width changes

    @Test func refitsToTheNewWidthWhenAtFitToWidth() {
        #expect(ZoomRange(fitToWidth: 0.5).rescaled(0.6, from: range) == 0.5)
    }

    @Test func keepsTheZoomRelativeToFitToWidthWhenZoomedIn() {
        // 2× fit-to-width stays 2× fit-to-width.
        #expect(ZoomRange(fitToWidth: 0.5).rescaled(1.2, from: range) == 1.0)
    }

    @Test func keepsTheRelativeZoomWhenFitToWidthGrows() {
        #expect(ZoomRange(fitToWidth: 1.2).rescaled(1.8, from: range) == 3.6)
    }
}
