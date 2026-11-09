import Testing

@MainActor
@Suite struct RenderedInkStabilityTests {
    /// Keeps the prints of these tests apart from `RENDER_DIFFERENCE` lines that real failures print.
    private let tag = "HELPER_TEST_DIFFERENCE"
    private let steady = [UInt8](repeating: 200, count: 16)
    private var other: [UInt8] {
        var changed = steady
        changed[4] = 10
        return changed
    }

    @Test func aTransientDifferenceSettlesIntoTheSteadyRender() throws {
        var renders = [other, steady, steady]
        let result = try RenderedInk.stablePixels(width: 2, label: "transient", logTag: tag) { renders.removeFirst() }
        #expect(result == steady)
        #expect(renders.isEmpty, "The steady render is confirmed by a second identical render")
    }

    @Test func aSteadyRenderNeedsTwoRendersOnly() throws {
        var count = 0
        let result = try RenderedInk.stablePixels(width: 2, label: "steady", logTag: tag) {
            count += 1
            return steady
        }
        #expect(result == steady)
        #expect(count == 2)
    }

    @Test func aRenderThatNeverSettlesFails() {
        var count = 0
        #expect(throws: RenderedInk.RenderError.self) {
            try RenderedInk.stablePixels(attempts: 5, width: 2, label: "never settles", logTag: tag) {
                count += 1
                return count.isMultiple(of: 2) ? steady : other
            }
        }
        #expect(count == 5)
    }
}
