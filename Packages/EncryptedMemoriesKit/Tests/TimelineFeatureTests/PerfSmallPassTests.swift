import AppKit
import GridCore
import Testing

@testable import TimelineFeature

@Suite("Perf small pass - draw slots")
@MainActor
struct PerfSmallPassDrawSlotTests {
    @Test func viewportDrawSlotsExcludeOverscanOnlyTiles() {
        let slots = [
            GridRenderSlot(index: 0, column: 0, row: -2, rect: CGRect(x: 0, y: -220, width: 100, height: 100)),
            GridRenderSlot(index: 1, column: 0, row: -1, rect: CGRect(x: 0, y: -20, width: 100, height: 100)),
            GridRenderSlot(index: 2, column: 0, row: 0, rect: CGRect(x: 0, y: 20, width: 100, height: 100)),
            GridRenderSlot(index: 3, column: 0, row: 9, rect: CGRect(x: 0, y: 390, width: 100, height: 100)),
            GridRenderSlot(index: 4, column: 0, row: 10, rect: CGRect(x: 0, y: 520, width: 100, height: 100)),
        ]

        let drawn = MetalGridCoordinator.viewportDrawSlots(slots, viewportSize: CGSize(width: 320, height: 480))

        #expect(drawn.map(\.index) == [1, 2, 3])
    }
}
