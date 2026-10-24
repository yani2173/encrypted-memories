import AppKit
import Testing

@testable import TimelineFeature

@MainActor
private final class SidebarFixture {
    let window: NSWindow
    let split = NSSplitViewController()
    let sidebarItem: NSSplitViewItem
    let probe = NSView()

    init(sidebarWidth: CGFloat, leadingContentWidth: CGFloat? = nil) {
        if let leadingContentWidth {
            let content = NSViewController()
            content.view = NSView()
            let item = NSSplitViewItem(contentListWithViewController: content)
            item.minimumThickness = leadingContentWidth
            item.maximumThickness = leadingContentWidth
            split.addSplitViewItem(item)
        }
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let detail = NSViewController()
        detail.view = NSView()
        detail.view.addSubview(probe)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = sidebarWidth
        sidebarItem.maximumThickness = sidebarWidth
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        // Never shown: layout alone gives the frames this test reads.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: true)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 900, height: 600))
        split.view.layoutSubtreeIfNeeded()
    }
}

struct SplitViewSidebarEdgeSourceTests {
    @Test @MainActor
    func readsTheSidebarEdgeOfTheSplitViewThatHostsAViewInItsDetail() throws {
        let fixture = SidebarFixture(sidebarWidth: 220)
        let source = try #require(SplitViewSidebarEdgeSource(hostedIn: fixture.probe))
        let edge = try #require(source.edge())
        #expect(abs(edge - 220) < 1)
    }

    @Test @MainActor
    func readsTheSidebarItemAndNotAnotherItemOfTheSplitView() throws {
        let fixture = SidebarFixture(sidebarWidth: 220, leadingContentWidth: 100)
        let source = try #require(SplitViewSidebarEdgeSource(hostedIn: fixture.probe))
        let sidebar = try #require(fixture.sidebarItem.viewController.view)
        let expected = sidebar.convert(sidebar.bounds, to: nil).maxX
        #expect(expected > 300, "the sidebar stands right of the leading item")
        #expect(abs(try #require(source.edge()) - expected) < 1)
    }

    @Test @MainActor
    func hasNoSourceOutsideASplitViewController() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        let plain = NSView()
        window.contentView?.addSubview(plain)
        #expect(SplitViewSidebarEdgeSource(hostedIn: plain) == nil)
        #expect(SplitViewSidebarEdgeSource(hostedIn: NSView()) == nil)
    }

    @Test @MainActor
    func stopsReadingWhenTheSidebarLeavesItsWindow() throws {
        let fixture = SidebarFixture(sidebarWidth: 220)
        let source = try #require(SplitViewSidebarEdgeSource(hostedIn: fixture.probe))
        #expect(source.edge() != nil)
        fixture.split.removeSplitViewItem(fixture.sidebarItem)
        #expect(source.edge() == nil, "no edge from a sidebar that no longer belongs to a window")
    }
}
