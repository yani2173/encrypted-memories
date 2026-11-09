import CoreGraphics
import GridCore
import Testing

@Suite struct GridBottomInsetPolicyTests {
    @Test func usesUnclippedOrientationForPartiallyVisibleBars() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let verticalVisible = CGRect(x: 0, y: 780, width: 40, height: 20)
        let horizontalVisible = CGRect(x: 0, y: 750, width: 20, height: 50)
        let vertical = GridBottomInsetPolicy.TabBar(
            frame: CGRect(x: 0, y: 600, width: 40, height: 200), visibleFrame: verticalVisible)
        let horizontal = GridBottomInsetPolicy.TabBar(
            frame: CGRect(x: 0, y: 750, width: 400, height: 50), visibleFrame: horizontalVisible)
        #expect(GridBottomInsetPolicy.inset(safeBottom: 80, viewport: viewport, tabBars: [vertical]) == 0)
        #expect(GridBottomInsetPolicy.inset(safeBottom: 80, viewport: viewport, tabBars: [horizontal]) == 80)
    }
    @Test func reservesBottomOnlyForAHorizontalBarInTheBottomRegion() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        func inset(_ bars: [CGRect]) -> CGFloat {
            GridBottomInsetPolicy.inset(
                safeBottom: 80, viewport: viewport,
                tabBars: bars.map { .init(frame: $0, visibleFrame: $0) })
        }

        #expect(inset([]) == 0)
        #expect(inset([CGRect(x: 360, y: 600, width: 40, height: 200)]) == 0)
        #expect(inset([CGRect(x: 0, y: 760, width: 400, height: 40)]) == 80)
        #expect(inset([CGRect(x: 0, y: 40, width: 400, height: 40)]) == 0)
        #expect(inset([CGRect(x: 0, y: 760, width: 0, height: 40)]) == 0)
        #expect(inset([CGRect(x: 0, y: 760, width: 40, height: 0)]) == 0)
        #expect(inset([CGRect(x: 0, y: 750, width: 49, height: 50)]) == 0)
        #expect(inset([CGRect(x: 0, y: 750, width: 50, height: 50)]) == 0)
        #expect(inset([CGRect(x: 0, y: 750, width: 51, height: 50)]) == 80)
        #expect(
            GridBottomInsetPolicy.inset(
                safeBottom: -1, viewport: viewport,
                tabBars: [.init(frame: CGRect(x: 0, y: 760, width: 400, height: 40), visibleFrame: viewport)]) == 0)
    }
}
