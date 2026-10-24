#if canImport(UIKit)
    import GridCore
    import os
    import PhotosCore
    import UIKit
    import UniformTypeIdentifiers

    /// Owns the native drag-out interaction for the timeline grid host.
    ///
    /// Strategy: the lift begins staging immediately (`DragOutStager.beginPrefetch`) while the user is
    /// still holding the item, and every `NSItemProvider` registers a file representation that hands
    /// back an `NSProgress` right away and completes with the staged URL once `awaitStaged` resolves.
    /// That gives the standard drop-side progress spinner for large 4K videos without materializing
    /// any plaintext up front. All state and delegate logic lives here; the host only stores the
    /// provider/reporter closures and this controller reference.
    @MainActor
    final class UIKitTimelineGridDragOutController: NSObject, UIDragInteractionDelegate,
        UIContextMenuInteractionDelegate
    {
        private static let logger = Logger(
            subsystem: "at.oncloud.encryptedmemories", category: "DragOut")

        var makeActivityViewController: (UIActivityItemsConfiguration) -> UIActivityViewController = {
            UIActivityViewController(activityItemsConfiguration: $0)
        }

        private weak var host: UIKitTimelineGridHostView?
        private var stager: DragOutStager?
        private var interaction: UIDragInteraction?
        private var contextMenuInteraction: UIContextMenuInteraction?
        private var progressByID: [PhotoUID: Progress] = [:]
        private var liftCount = 0
        private var reportedFailure = false
        /// True after the lifted items start moving; a stationary lift still permits the menu.
        private(set) var sessionActive = false
        /// UIDs already carried by the active session; `itemsForAddingTo` dedupes against it so a
        /// second finger cannot stack the same photo twice.
        private var sessionItemUIDs: Set<PhotoUID> = []
        private let hapticFeedback = UIImpactFeedbackGenerator(style: .medium)

        init(host: UIKitTimelineGridHostView) {
            self.host = host
            super.init()
        }

        deinit {
            // Nonisolated deinit: capture the main-actor state, then run the final teardown on the
            // main actor (same pattern as `UIKitMemoryPressureCoordinator.deinit`).
            let interaction = interaction
            let stager = stager
            Task { @MainActor in
                interaction?.isEnabled = false
                await stager?.finishAndCleanup()
            }
        }

        /// The on-demand staging directory for drag-out originals.
        private static var stagingDirectory: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("DragOut", isDirectory: true)
        }

        /// A fresh per-session staging subdirectory keeps concurrent sessions from sweeping each
        /// other's in-flight downloads: the stager's orphan sweep removes stale `.download` files,
        /// and a second drag reusing the shared directory could delete the first session's files.
        private static func makeSessionStagingDirectory() -> URL {
            Self.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }

        /// Delays session teardown after the drag ends: iOS can resolve item-provider loads shortly
        /// after `didEndWith`, so an immediate cleanup would cancel in-flight staging (4K/2 GB
        /// videos) and fail late load handlers. Bounded so plaintext staged files persist at most
        /// this long after a session ends.
        private static let sessionDeliveryGraceNanoseconds: UInt64 = 60_000_000_000

        private nonisolated static func kind(for failure: DragOutStagingFailure) -> DragOutFailureKind {
            switch failure {
            case .cancelled: .cancelled
            case .diskSpaceInsufficient: .insufficientSpace
            case .writeFailed: .writeFailed
            }
        }

        private nonisolated static func nsError(for failure: DragOutStagingFailure) -> NSError {
            let kind = kind(for: failure)
            return NSError(
                domain: "com.encryptedmemories.dragout",
                code: {
                    switch kind {
                    case .insufficientSpace: 1
                    case .writeFailed: 2
                    case .cancelled: 3
                    }
                }(),
                userInfo: [NSLocalizedDescriptionKey: kind.localizedMessage]
            )
        }

        private static func typeIdentifier(for item: PhotoItem) -> String {
            UTType(mimeType: item.mediaType)?.identifier ?? UTType.data.identifier
        }

        // MARK: - Installation

        func install(on view: UIView) {
            guard interaction == nil else { return }
            let interaction = UIDragInteraction(delegate: self)
            interaction.isEnabled = host?.dragOutProvider != nil
            view.addInteraction(interaction)
            self.interaction = interaction
            let contextMenu = UIContextMenuInteraction(delegate: self)
            view.addInteraction(contextMenu)
            self.contextMenuInteraction = contextMenu
        }

        func updateEnabled(provider: (any OriginalFileProvider)?) {
            interaction?.isEnabled = provider != nil
        }

        // MARK: - Lift resolution

        private func liftItems(around pressed: PhotoItem) -> [PhotoItem] {
            guard let host else { return [pressed] }
            return host.dragOutLiftItems(around: pressed)
        }

        private func beginStagingIfNeeded(for items: [PhotoItem]) {
            guard stager == nil, let provider = host?.dragOutProvider, !items.isEmpty else { return }
            let stager = DragOutStager(
                fileProvider: provider, stagingDirectory: Self.makeSessionStagingDirectory())
            self.stager = stager
            liftCount = items.count
            reportedFailure = false
            Task { [weak self] in
                // One sequential setup task: hop onto the stager to install the progress relay first
                // (actor-isolated setter), then start the prefetch. A single task keeps the order
                // deterministic; parallel awaits could let `beginPrefetch` overtake the handler.
                await stager.setProgressHandler { [weak self] uid, fraction in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let clamped = min(max(fraction, 0), 1)
                        self.progressByID[uid]?.completedUnitCount = Int64(clamped * 1000)
                        self.host?.dragOutProgressReporter?(self.liftCount, clamped)
                    }
                }
                let decision = await stager.beginPrefetch(items: items)
                guard let self, !decision.isAllowed else { return }
                // Denied preflight (primarily the free-space margin). The per-item load handlers still
                // resolve their concrete failure; surface the denial once so the user learns why.
                self.reportFailure(.insufficientSpace)
            }
        }

        /// Makes a drag item whose file representation resolves to the given stager's staged URL.
        /// The context-menu actions capture the item's provider the same way a drag session does, so
        /// Share/Copy reuse one load path: staging starts now, the system resolves lazily.
        private func makeDragItem(
            for file: OutboundMediaFile, stager: DragOutStager?, action: ActionStagingLifetime? = nil
        ) -> UIDragItem {
            let item = file.item
            let provider = NSItemProvider()
            let uid = item.uid
            let typeIdentifier = Self.typeIdentifier(for: item)
            // Capture the session's stager at item creation. iOS resolves item-provider loads
            // around and shortly after `didEndWith`; reading `self.stager` inside the load handler
            // could pick up the NEXT session's stager (late load of the previous drag) or nil
            // (after teardown). Capturing keeps every load bound to the session that promised it.
            // Context-menu items pass their dedicated `actionStager` explicitly.
            let sessionStager = stager
            provider.registerFileRepresentation(
                forTypeIdentifier: typeIdentifier, fileOptions: [], visibility: .all
            ) { [weak self] completion in
                // Return the progress immediately so the drop side shows its standard spinner while the
                // staged file resolves asynchronously. The completion signature is
                // `(url, coordinated, error)`: staged copies are private temporaries, so coordination
                // is never required and `coordinated` is always false.
                let progress = Progress(totalUnitCount: 1000)
                // Pasteboard reads can synchronously wait for this provider on the main thread.
                // Resolve the file independently; only progress/error presentation hops to UIKit.
                Task.detached(priority: .userInitiated) { [weak self, action] in
                    defer { withExtendedLifetime(action) {} }
                    guard let sessionStager else {
                        completion(nil, false, CocoaError(.fileNoSuchFile))
                        return
                    }
                    Task { @MainActor [weak self] in self?.progressByID[uid] = progress }
                    let result = await sessionStager.awaitStaged(uid: uid)
                    Task { @MainActor [weak self] in self?.progressByID[uid] = nil }
                    switch result {
                    case .success(let url):
                        progress.completedUnitCount = progress.totalUnitCount
                        // Mark delivered before handing the URL to the system: the drag session can
                        // end (and cleanup run) as soon as `completion` runs, which would otherwise
                        // delete the file while the destination is still copying it.
                        await sessionStager.markDelivered(uid: uid)
                        completion(url, false, nil)
                    case .failure(let failure):
                        completion(nil, false, Self.nsError(for: failure))
                        Task { @MainActor [weak self] in
                            self?.reportFailure(Self.kind(for: failure), action: action)
                        }
                    }
                }
                return progress
            }
            let dragItem = UIDragItem(itemProvider: provider)
            // The motion video of a Live Photo lifts with the still's thumbnail.
            dragItem.localObject = file.picked
            // Per-item image preview, matching Apple Photos: the actual thumbnail bitmap with the
            // grid's current content mode and tile corner radius. Fallback is the system
            // default preview (no provider set), never nil-provider hiding.
            if let preview = makePreviewView(for: file.picked) {
                dragItem.previewProvider = { UIDragPreview(view: preview) }
            }
            return dragItem
        }

        /// Builds the detached preview view for a dragged photo: a `UIImageView` with the feed's
        /// cached bitmap sized through the same `TileContentFitter` geometry the grid draws with.
        /// Returns nil when no bitmap is cached (the system default preview then applies).
        private func makePreviewView(for item: PhotoItem) -> UIView? {
            guard let host,
                let cgImage = host.thumbnailFeed?.memoryCGImage(for: item.uid),
                let context = host.currentGridContext(),
                let index = host.itemIndexByUID[item.uid],
                let slotRect = context.engine.slotRect(
                    flatIndex: index, level: context.level, width: host.bounds.width,
                    columnPhase: host.committedPhase)
            else { return nil }
            let pixels = CGSize(width: cgImage.width, height: cgImage.height)
            let mode = context.engine.effectiveContentMode(preferred: host.displayMode, level: context.level)
            let layout = TileContentFitter.fit(
                slotRect: slotRect, mediaPixelSize: pixels, displayMode: mode)
            let radius = GridCornerRadiusPolicy.radius(forSlotSidePoints: slotRect.maxX - slotRect.minX)
            let imageView = UIImageView(image: UIImage(cgImage: cgImage))
            imageView.frame = host.scrollView.convert(layout.contentRect, from: host.contentView)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = radius
            return imageView
        }

        /// Extends the active session's staging with newly lifted items. The stager skips UIDs it
        /// already has jobs for, so this is additive on the same session stager.
        private func extendStaging(with items: [PhotoItem]) {
            guard let stager, !items.isEmpty else { return }
            Task { [weak self] in
                let decision = await stager.beginPrefetch(items: items)
                guard let self, !decision.isAllowed else { return }
                self.reportFailure(.insufficientSpace)
            }
        }

        /// Resets the session's UI state immediately, but delays the final cleanup: iOS can resolve
        /// item-provider loads shortly after `didEndWith`, so an immediate `finishAndCleanup` would
        /// cancel in-flight staging of large media and delete files a late load still needs. A newer
        /// session installs its own stager in the meantime, which the captured stager is unaffected
        /// by (each session stages into its own UUID directory).
        private func endSession() {
            sessionActive = false
            sessionItemUIDs.removeAll()
            progressByID.removeAll()
            liftCount = 0
            let stager = stager
            self.stager = nil
            Task {
                try? await Task.sleep(nanoseconds: Self.sessionDeliveryGraceNanoseconds)
                await stager?.finishAndCleanup()
            }
        }

        // MARK: - UIDragInteractionDelegate

        public func dragInteraction(
            _ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession
        ) -> [UIDragItem] {
            guard let host,
                host.dragOutProvider != nil,
                // Reuse the host's tap hit-testing exactly; no duplicated grid geometry here.
                let pressed = host.item(at: session.location(in: host.contentView)),
                // In selection mode a hold on an unselected photo selects a range instead of lifting it.
                !host.swipeSelection.ownsLongPress(on: pressed)
            else { return [] }
            let items = liftItems(around: pressed)
            // A Live Photo leaves as its still and its motion video.
            let files = OutboundMedia.files(for: items)
            beginStagingIfNeeded(for: files.map(\.item))
            sessionItemUIDs = Set(items.map(\.uid))
            Self.logger.notice(
                "Drag began: \(items.count, privacy: .public) item(s), nodes=\(items.map(\.uid.nodeID), privacy: .public)"
            )
            hapticFeedback.impactOccurred()
            return files.map { makeDragItem(for: $0, stager: stager) }
        }

        public func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            sessionActive = true
        }

        public func dragInteraction(
            _ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession
        ) -> UITargetedDragPreview? {
            guard let photo = item.localObject as? PhotoItem else { return nil }
            return makeTargetedPreview(for: photo)
                ?? interaction.view.flatMap { $0.window == nil ? nil : UITargetedDragPreview(view: $0) }
        }

        public func dragInteraction(
            _ interaction: UIDragInteraction,
            itemsForAddingTo session: UIDragSession,
            withTouchAt point: CGPoint
        ) -> [UIDragItem] {
            guard let host,
                host.dragOutProvider != nil,
                sessionActive,
                // The touch point arrives in the interaction view's coordinate space (the scroll
                // view); the host hit-tests in content coordinates.
                let pressed = host.item(at: host.scrollView.convert(point, to: host.contentView))
            else { return [] }
            // Only add photos the session does not already carry, and never remove what's lifted.
            let newItems = liftItems(around: pressed).filter { !sessionItemUIDs.contains($0.uid) }
            guard !newItems.isEmpty else { return [] }
            let newFiles = OutboundMedia.files(for: newItems)
            extendStaging(with: newFiles.map(\.item))
            sessionItemUIDs.formUnion(newItems.map(\.uid))
            Self.logger.notice(
                "Drag added: \(newItems.count, privacy: .public) item(s), now \(self.sessionItemUIDs.count, privacy: .public) total"
            )
            hapticFeedback.impactOccurred()
            return newFiles.map { makeDragItem(for: $0, stager: stager) }
        }

        public func dragInteraction(
            _ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation
        ) {
            // Covers both completed and cancelled sessions; cancellation reports `.cancel`.
            Self.logger.notice("Drag ended: operation=\(operation.rawValue, privacy: .public)")
            endSession()
        }

        // MARK: - UIContextMenuInteractionDelegate

        /// The pressed photo anchors the preview, even when the action carries multiple selected items.
        private var contextMenuPreviewItem: PhotoItem?

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            // A drag already in flight owns the gesture; never stack a menu on top of it. Without a
            // provider there is nothing to stage, so the menu's actions would silently no-op.
            guard !sessionActive, let host, host.dragOutProvider != nil else { return nil }
            // The delegate hands us the location in the interaction's view (the scroll view);
            // hit-testing needs the engine's content space (origin at the library top, y down).
            guard let pressed = host.item(at: host.contentView.convert(location, from: host.scrollView)),
                !host.swipeSelection.ownsLongPress(on: pressed)
            else {
                return nil
            }
            let items = liftItems(around: pressed)
            guard !items.isEmpty else { return nil }
            contextMenuPreviewItem = pressed
            Self.logger.notice("Context menu: \(items.count, privacy: .public) item(s)")
            let configuration = UIContextMenuConfiguration(
                identifier: "timeline.contextMenu" as NSString,
                previewProvider: { [weak self] in self?.makeMenuPreviewController(for: pressed) },
                actionProvider: { [weak self] _ in
                    self?.makeActionMenu(items: items)
                }
            )
            configuration.preferredMenuElementOrder = .fixed
            configuration.badgeCount = items.count
            return configuration
        }

        /// UIKit positions the preview/menu from the pressed tile, including screen-edge avoidance.
        func makeMenuPreviewController(for item: PhotoItem) -> UIViewController? {
            guard let preview = makePreviewView(for: item), let host else { return nil }
            let available = host.window?.safeAreaLayoutGuide.layoutFrame.size ?? host.bounds.size
            let scale = min(
                min(available.width * 0.8, 420) / max(preview.bounds.width, 1),
                available.height * 0.5 / max(preview.bounds.height, 1))
            let size = CGSize(width: preview.bounds.width * scale, height: preview.bounds.height * scale)
            let controller = UIViewController()
            preview.frame = CGRect(origin: .zero, size: size)
            preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view = preview
            controller.preferredContentSize = size
            return controller
        }

        /// Matches Apple Photos: the menu highlights the actual thumbnail with the grid's tile
        /// corner radius. Falls back to the system default preview when no bitmap is cached.
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: NSCopying
        ) -> UITargetedPreview? {
            contextMenuPreviewItem.flatMap(makeTargetedPreview)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            dismissalPreviewForItemWithIdentifier identifier: NSCopying
        ) -> UITargetedPreview? {
            contextMenuPreviewItem.flatMap(makeTargetedPreview)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            // Keep the anchor available while UIKit asks for the dismissal preview.
            animator?.addCompletion { [weak self] in
                self?.contextMenuPreviewItem = nil
            }
            if animator == nil { contextMenuPreviewItem = nil }
        }

        private func makeTargetedPreview(for item: PhotoItem) -> UITargetedDragPreview? {
            guard let host, host.scrollView.window != nil else { return nil }
            guard let previewView = makePreviewView(for: item) else { return nil }
            guard let context = host.currentGridContext(),
                let index = host.itemIndexByUID[item.uid],
                let slotRect = context.engine.slotRect(
                    flatIndex: index, level: context.level, width: host.bounds.width,
                    columnPhase: host.committedPhase)
            else { return nil }
            // slotRect lives in the engine's content space (contentView spans the full content size
            // at origin .zero, so its coordinate space IS the engine's space: see `handleTap`);
            // convert the slot center from contentView into the scroll view's coordinates.
            let slotCenter = host.scrollView.convert(
                CGPoint(x: slotRect.midX, y: slotRect.midY), from: host.contentView)
            // An explicit target makes the highlight render from `previewView` even though the view is
            // detached (never added to any window); the container only anchors the geometry.
            let parameters = UIPreviewParameters()
            parameters.visiblePath = UIBezierPath(
                roundedRect: previewView.bounds, cornerRadius: previewView.layer.cornerRadius)
            return UITargetedDragPreview(
                view: previewView,
                parameters: parameters,
                target: UIPreviewTarget(container: host.scrollView, center: slotCenter))
        }

        func makeActionMenu(items: [PhotoItem]) -> UIMenu {
            let offered = host?.contextMenuActions?(items) ?? [.copy, .share]
            let groups: [UIMenuElement] = (0...3).compactMap { group in
                let actions = offered.filter { $0.group == group }.map { action in
                    UIAction(
                        title: action.title, image: UIImage(systemName: action.systemImage),
                        identifier: UIAction.Identifier(action.rawValue),
                        attributes: action == .trash ? .destructive : []
                    ) { [weak self] _ in
                        guard let self else { return }
                        switch action {
                        case .share: self.shareViaActivityController(items: items)
                        case .copy: self.copyToPasteboard(items: items)
                        default: self.host?.onContextMenuAction?(action, items)
                        }
                    }
                }
                guard !actions.isEmpty else { return nil }
                let section = UIMenu(options: .displayInline, children: actions)
                section.preferredElementSize = group == 0 ? .medium : .large
                return section
            }
            return UIMenu(children: groups)
        }

        private func reportFailure(_ kind: DragOutFailureKind, action: ActionStagingLifetime? = nil) {
            guard !(action?.reportedFailure ?? reportedFailure) else { return }
            if let action { action.reportedFailure = true } else { reportedFailure = true }
            host?.onDragOutFailed?(kind)
        }

        /// Each action has its own failure latch; a late Copy load cannot suppress a new Share error.
        private func beginActionStaging(action: ActionStagingLifetime, items: [PhotoItem]) {
            let stager = action.stager
            Task.detached(priority: .userInitiated) { [weak self] in
                let decision = await stager.beginPrefetch(items: items)
                guard !decision.isAllowed else { return }
                await self?.reportFailure(.insufficientSpace, action: action)
            }
        }

        /// Shares the lifted items through the system share sheet, backed by a dedicated
        /// action stager over the same original-file provider: staging starts now, the activity
        /// controller's item providers resolve asynchronously to the staged URLs.
        private func shareViaActivityController(items: [PhotoItem]) {
            guard !items.isEmpty, let host, let provider = host.dragOutProvider else { return }
            // Resolve the presenter before allocating a staging owner.
            var responder: UIResponder? = host
            var presenter: UIViewController?
            while let current = responder {
                if let vc = current as? UIViewController, vc.presentedViewController == nil,
                    vc.viewIfLoaded?.window != nil
                {
                    presenter = vc
                    break
                }
                responder = current.next
            }
            guard let presenter else {
                Self.logger.error("Context menu share: no presenting view controller found")
                return
            }
            let stager = DragOutStager(
                fileProvider: provider, stagingDirectory: Self.makeSessionStagingDirectory())
            let action = ActionStagingLifetime(stager: stager)
            let files = OutboundMedia.files(for: items)
            let dragItems = files.map { makeDragItem(for: $0, stager: stager, action: action) }
            let configuration = UIActivityItemsConfiguration(itemProviders: dragItems.map(\.itemProvider))
            let activityVC = makeActivityViewController(configuration)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = host
                popover.sourceRect = host.bounds
            }
            // UIKit owns the presented controller. Capture only its staging lifetime here, never
            // activityVC itself: a controller retaining its own completion block forms a cycle.
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                action.finishAfterDeliveryGrace()
            }
            beginActionStaging(action: action, items: files.map(\.item))
            presenter.present(activityVC, animated: true)
        }

        func copyToPasteboard(items: [PhotoItem], pasteboard: UIPasteboard = .general) {
            guard !items.isEmpty, let host, let provider = host.dragOutProvider else { return }
            let stager = DragOutStager(
                fileProvider: provider, stagingDirectory: Self.makeSessionStagingDirectory())
            let action = ActionStagingLifetime(stager: stager)
            let files = OutboundMedia.files(for: items)
            let dragItems = files.map { makeDragItem(for: $0, stager: stager, action: action) }
            // The providers capture this copy's stager; opening Share must not retire it.
            beginActionStaging(action: action, items: files.map(\.item))
            pasteboard.itemProviders = dragItems.map(\.itemProvider)
        }
    }

    /// The system's item providers own action staging, so leaving a grid cannot cancel Copy.
    /// Action files remain app-owned copies even after delivery and must eventually be deleted.
    @MainActor private final class ActionStagingLifetime {
        let stager: DragOutStager
        var reportedFailure = false

        init(stager: DragOutStager) { self.stager = stager }

        func finishAfterDeliveryGrace() {
            Self.scheduleCleanup(stager)
        }

        deinit { Self.scheduleCleanup(stager) }

        private nonisolated static func scheduleCleanup(_ stager: DragOutStager) {
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await stager.cancelAll()
            }
        }
    }

    // MARK: - Host hooks (all drag-out host logic; stored properties live in the class body)

    extension UIKitTimelineGridHostView {
        /// Lazily attaches the drag-out interaction once a backend provider is injected. Idempotent, so
        /// SwiftUI's repeated `updateUIView` assignments of the same provider never double-install.
        func installDragOutInteractionIfNeeded() {
            dragOutController?.updateEnabled(provider: dragOutProvider)
            guard dragOutProvider != nil, dragOutController == nil else { return }
            let controller = UIKitTimelineGridDragOutController(host: self)
            controller.install(on: scrollView)
            dragOutController = controller
        }

        /// Which items a lift carries: a selected photo in selection mode drags the entire selection;
        /// anything else drags exactly itself (no implicit auto-select).
        func dragOutLiftItems(around pressed: PhotoItem) -> [PhotoItem] {
            guard selectionMode, selectedUIDs.contains(pressed.uid), !selectedUIDs.isEmpty else {
                return [pressed]
            }
            let byUID = Dictionary(accessibilityItems.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            return selectedUIDs.compactMap { byUID[$0] }
        }
    }
#endif
