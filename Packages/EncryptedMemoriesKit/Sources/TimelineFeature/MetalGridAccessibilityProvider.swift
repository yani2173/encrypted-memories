import AppKit
import GridCore
import PhotosCore
import TimelineCore

/// Exposes visible Metal grid cells as accessibility elements because the renderer has no per-cell views.
/// Each element provides its media type, capture date, selection state, and an action that opens the viewer.
@MainActor
final class MetalGridAccessibilityProvider {
    private weak var host: NSView?
    private weak var coordinator: MetalGridCoordinator?
    var items: [PhotoItem] = []
    var selected: Set<PhotoUID> = [] {
        didSet {
            guard selected != oldValue, let host else { return }
            // Preserve the focused element while updating the value that VoiceOver reads after a press.
            for case let element as MetalGridA11yElement in host.accessibilityChildren() ?? [] {
                guard let uid = element.uid else { continue }
                element.setAccessibilitySelected(selected.contains(uid))
            }
            NSAccessibility.post(element: host, notification: .selectedChildrenChanged)
        }
    }
    var onOpen: ((PhotoUID) -> Void)?
    /// Programmatic activation (VoiceOver press) that respects the current selection mode. Preferred
    /// over `onOpen` when set; the closure reports whether the activation succeeded.
    var onActivate: ((PhotoUID) -> Bool)?

    init(host: NSView, coordinator: MetalGridCoordinator) {
        self.host = host
        self.coordinator = coordinator
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.group)
        host.setAccessibilityLabel(L10n.string("a11y.photo_library_grid"))
    }

    // Coalesce viewport updates to 10 Hz and schedule a final rebuild. VoiceOver does not need per-frame
    // element geometry, and rebuilding every visible element on each scroll frame is unnecessarily expensive.
    private var lastRebuild: Date = .distantPast
    private var trailingScheduled = false
    private let minRebuildInterval: TimeInterval = 0.1

    /// Request an accessibility-element rebuild (throttled). Safe to call on every viewport/selection change.
    func invalidate() {
        let now = Date()
        let since = now.timeIntervalSince(lastRebuild)
        if since >= minRebuildInterval {
            lastRebuild = now
            rebuildNow()
        } else if !trailingScheduled {
            trailingScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (minRebuildInterval - since)) { [weak self] in
                guard let self else { return }
                self.trailingScheduled = false
                self.lastRebuild = Date()
                self.rebuildNow()
            }
        }
    }

    /// Rebuild the visible accessibility elements and assign them to the host (the actual work).
    private func rebuildNow() {
        guard let host, let coordinator, let window = host.window else { return }
        let hostHeight = host.bounds.height
        var elements: [NSAccessibilityElement] = []
        for cell in coordinator.visibleCells() {
            guard cell.flatIndex < items.count else { continue }
            let item = items[cell.flatIndex]
            let vp = MetalGridGeometry.viewportRect(
                contentRect: cell.rect, visibleOrigin: CGPoint(x: 0, y: coordinator.scrollOriginY))
            // Translate the engine-space rectangle before converting it to screen coordinates.
            // Convert from viewport coordinates to host, window, and screen coordinates.
            let localYUp = CGRect(
                x: vp.minX + coordinator.leadingObstructionInset, y: hostHeight - vp.maxY, width: vp.width,
                height: vp.height)
            let screen = window.convertToScreen(host.convert(localYUp, to: nil))
            let element = MetalGridA11yElement()
            element.setAccessibilityParent(host)
            element.setAccessibilityRole(.image)
            element.setAccessibilityLabel(
                Self.label(for: item, backupState: coordinator.uploadBadges.accessibilityDescription(for: item.uid)))
            element.setAccessibilityFrame(screen)
            element.setAccessibilitySelected(selected.contains(item.uid))
            element.uid = item.uid
            element.onActivate = onActivate
            element.onOpen = onOpen
            elements.append(element)
        }
        host.setAccessibilityChildren(elements)
    }

    /// Shared formatter - `DateFormatter()` is expensive to allocate, and `label(for:)` is called once per
    /// visible cell per rebuild, so a per-call instance was a real cost.
    private static let labelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    /// VoiceOver label for a photo: kind + capture date, then its backup state when it has one.
    static func label(for item: PhotoItem, backupState: String? = nil) -> String {
        let kind = item.isVideo ? L10n.string("a11y.video") : L10n.string("a11y.photo")
        let label = "\(kind), \(labelFormatter.string(from: item.captureTime))"
        return backupState.map { "\(label), \($0)" } ?? label
    }

    /// Whether new badges can change a label: the pause starts or ends, or a photo changes its badge while
    /// paused, for example when it finishes.
    static func badgesChangeLabels(from old: PendingUploadBadges, to new: PendingUploadBadges) -> Bool {
        new != old && (new.isPaused || old.isPaused)
    }
}

/// An accessibility element whose press action activates its photo. `onActivate` routes through the
/// current selection mode (toggle in selection mode, open the viewer otherwise); `onOpen` is the legacy
/// direct-open fallback.
final class MetalGridA11yElement: NSAccessibilityElement {
    var uid: PhotoUID?
    var onActivate: ((PhotoUID) -> Bool)?
    var onOpen: ((PhotoUID) -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let uid else { return false }
        if let onActivate {
            return onActivate(uid)
        }
        guard let onOpen else { return false }
        onOpen(uid)
        return true
    }
}
