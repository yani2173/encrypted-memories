import CoreGraphics

/// Reserves the bottom safe area only when a horizontal tab bar occupies it.
public enum GridBottomInsetPolicy {
    public struct TabBar: Equatable {
        public let frame: CGRect
        public let visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    public static func inset(safeBottom: CGFloat, viewport: CGRect, tabBars: [TabBar]) -> CGFloat {
        let bottom = max(0, safeBottom)
        let bottomRegion = CGRect(x: viewport.minX, y: viewport.maxY - bottom, width: viewport.width, height: bottom)
        return tabBars.contains {
            !$0.frame.isEmpty && $0.frame.width > $0.frame.height && !$0.visibleFrame.isEmpty
                && $0.visibleFrame.intersects(bottomRegion)
        } ? bottom : 0
    }
}
