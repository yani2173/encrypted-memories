import AppKit
import GridCore
import MetalKit
import PhotosCore
import Testing

@testable import TimelineFeature

/// The real grid host beside a real split view (#183). A test process has no running application, so AppKit does
/// not animate the sidebar here. The test moves the divider through edge sequences recorded from AppKit's own sidebar
/// animation instead, and steps the host with a clock it controls. After each step the grid edge must stay with the
/// sidebar edge. Nothing waits, and the window is never shown. AppKit keeps a sidebar item at least 10 pt wide, so
/// the fixture shifts every recorded edge by 10 pt; the sidebar then travels between 10 and 230 pt.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalGridSidebarFollowHostTests {
    private static let closedEdge: CGFloat = 10
    private static let openEdge: CGFloat = 230
    private static let tolerance: CGFloat = 2

    @Test func theHostKeepsTheGridEdgeWithTheSidebarEdgeThroughRecordedAnimations() throws {
        let fixture = try SplitHostFixture(sidebarWidth: Self.openEdge)
        let host = fixture.host
        let coordinator = host.coordinator
        var now: CFTimeInterval = 0
        host.sidebarClock = { now }
        host.eventLeadingInset = Self.openEdge  // the first inset only arms the grid; no transition yet
        fixture.layout()
        #expect(coordinator.contentSize().height > 0)

        for opening in [false, true, false] {
            let edges =
                opening
                ? GridResizePresentationTests.recordedOpeningEdges
                : GridResizePresentationTests.recordedClosingEdges
            let from = opening ? Self.closedEdge : Self.openEdge
            let to = opening ? Self.openEdge : Self.closedEdge
            fixture.setSidebarEdge(from)
            host.eventLeadingInset = to  // the library detail passes the new inset when the toggle starts
            #expect(coordinator.isSidebarResizing, "a sidebar toggle starts a transition")

            let size = host.bounds.size
            let sources = coordinator.sidebarPresentationSlots(viewportSize: size, fraction: 0)
            let targets = coordinator.sidebarPresentationSlots(viewportSize: size, fraction: 1)
            let leading = try #require(sources.first { $0.column == 0 })
            let leadingTarget = try #require(targets.first { $0.index == leading.index })
            let travelX = leadingTarget.rect.minX - leading.rect.minX
            #expect(abs(travelX) > 100)

            var worstLead: CGFloat = 0
            var followed = 0
            for recorded in edges {
                let edge = recorded + Self.closedEdge
                fixture.setSidebarEdge(edge)
                now += 0.004
                host.step()
                if edge == to {
                    #expect(!coordinator.isSidebarResizing, "the transition ends with the sidebar")
                    break
                }
                #expect(coordinator.isSidebarResizing, "the transition follows the sidebar at edge \(edge)")
                let slots = coordinator.sidebarPresentationSlots(
                    viewportSize: size, fraction: coordinator.presentationSidebarFraction)
                guard let slot = slots.first(where: { $0.index == leading.index }) else { continue }
                let gridEdge = from + (slot.rect.minX - leading.rect.minX) / travelX * (to - from)
                let lead = (gridEdge - fixture.sidebarEdge) * (to > from ? 1 : -1)
                if abs(lead) > abs(worstLead) { worstLead = lead }
                followed += 1
            }
            #expect(followed >= edges.count - 3, "the grid followed \(followed) of \(edges.count) frames")
            #expect(abs(worstLead) <= Self.tolerance, "the grid edge was \(worstLead) pt from the sidebar edge")
            #expect(!coordinator.isSidebarResizing)
            #expect(coordinator.sidebarObstructionInset == to)
        }
    }

    @Test func aHostOutsideASplitViewFollowsTheClockAndEndsAfterTwoHundredTwentyMilliseconds() throws {
        let fixture = try SplitHostFixture(sidebarWidth: Self.openEdge, hostedInSplitView: false)
        let host = fixture.host
        let coordinator = host.coordinator
        var now: CFTimeInterval = 0
        host.sidebarClock = { now }
        host.eventLeadingInset = Self.openEdge
        fixture.layout()

        host.eventLeadingInset = 0
        #expect(coordinator.isSidebarResizing)
        now += 0.2
        host.step()
        #expect(coordinator.isSidebarResizing, "the clock has not run out at 200 ms")
        now += 0.02
        host.step()
        #expect(!coordinator.isSidebarResizing, "the clock ends the transition at 220 ms")
        #expect(coordinator.sidebarObstructionInset == 0)
    }
}

/// A split view controller with a sidebar item and a detail item that holds the grid host at a fixed, full width,
/// like the floating sidebar of the library window.
@MainActor
private final class SplitHostFixture {
    let window: UnseenWindow
    let split = NSSplitViewController()
    let sidebarItem: NSSplitViewItem
    let host: MetalGridScrollHost

    init(sidebarWidth: CGFloat, hostedInSplitView: Bool = true) throws {
        _ = NSApplication.shared
        let device = try #require(MTLCreateSystemDefaultDevice())
        host = try #require(
            MetalGridScrollHost(
                device: device, dataSource: FollowDataSource(count: 600), gridProfile: .testRegularTimeline))
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let detail = NSViewController()
        detail.view = NSView()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 0
        sidebarItem.maximumThickness = sidebarWidth
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        host.frame = NSRect(x: 0, y: 0, width: 1_080, height: 720)
        host.autoresizingMask = []
        if hostedInSplitView {
            window = UnseenWindow(contentViewController: split)
            window.setContentSize(NSSize(width: 1_080, height: 720))
            detail.view.addSubview(host)
        } else {
            // The controller's view would still lead to the split view controller through the responder chain.
            window = UnseenWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.contentView?.addSubview(host)
        }
        layout()
        setSidebarEdge(sidebarWidth)
    }

    func layout() {
        split.view.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    func setSidebarEdge(_ edge: CGFloat) {
        split.splitView.setPosition(edge, ofDividerAt: 0)
        split.view.layoutSubtreeIfNeeded()
    }

    /// The right edge of the sidebar in window coordinates.
    var sidebarEdge: CGFloat {
        let view = sidebarItem.viewController.view
        return view.convert(view.bounds, to: nil).maxX
    }
}

/// A window the host sees as visible, so its frame pump runs although nobody looks at it.
@MainActor
private final class UnseenWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

@MainActor
private final class FollowDataSource: MetalGridDataSource {
    let label = "sidebar-follow-test"
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    var onImagesAvailable: (() -> Void)?

    init(count: Int) {
        sectionCounts = [count]
        flatUIDs = (0..<count).map { PhotoUID(volumeID: "v", nodeID: "\($0)") }
    }

    func image(for uid: PhotoUID) -> CGImage? { nil }
    func warm(_ requests: [ThumbnailRequest]) {}
    func hasImage(for uid: PhotoUID) -> Bool { false }
}
