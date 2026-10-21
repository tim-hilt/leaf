import Testing

@testable import LeafPDF

@Suite struct TextSizeTests {
    @Test func keyboardStepsGrowAndShrinkTheText() {
        #expect(TextSize.zoomedIn(from: 1) == 1.25)
        #expect(TextSize.zoomedOut(from: 1.25) == 1)
    }

    @Test func theTextStaysBetweenHalfAndTripleTheDesignedSize() {
        #expect(TextSize.zoomedOut(from: 0.5) == 0.5)
        #expect(TextSize.zoomedIn(from: 3) == 3)
        #expect(TextSize.clamped(10) == 3)
        #expect(TextSize.clamped(0.1) == 0.5)
        #expect(TextSize.clamped(1.7) == 1.7)
    }
}
