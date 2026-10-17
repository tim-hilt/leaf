import CoreGraphics
import Testing

@testable import LeafPDF

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
}
