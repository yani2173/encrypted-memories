import AppKit

/// Reads the live right edge of the sidebar column of the split view that hosts a view.
///
/// AppKit animates the sidebar with its own curve and duration. The grid asks this source for the real edge on each
/// frame of a sidebar toggle, so it can follow the sidebar instead of running a parallel animation. It holds the
/// sidebar view weakly and exists only while a toggle runs.
@MainActor
struct SplitViewSidebarEdgeSource {
    private weak var sidebarView: NSView?

    /// Nil when `view` is not hosted in a split view controller that has a sidebar item.
    init?(hostedIn view: NSView) {
        guard let controller = Self.splitViewController(hosting: view),
            let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar })?
                .viewController.view
        else { return nil }
        sidebarView = sidebar
    }

    /// The sidebar's right edge in window coordinates, or nil once the sidebar left its window.
    func edge() -> CGFloat? {
        guard let sidebarView, sidebarView.window != nil else { return nil }
        return sidebarView.convert(sidebarView.bounds, to: nil).maxX
    }

    /// Walks the responder chain, then each controller's parents, to the enclosing split view controller.
    private static func splitViewController(hosting view: NSView) -> NSSplitViewController? {
        var responder: NSResponder? = view
        while let current = responder {
            var controller = current as? NSViewController
            while let candidate = controller {
                if let split = candidate as? NSSplitViewController { return split }
                controller = candidate.parent
            }
            responder = current.nextResponder
        }
        return nil
    }
}
