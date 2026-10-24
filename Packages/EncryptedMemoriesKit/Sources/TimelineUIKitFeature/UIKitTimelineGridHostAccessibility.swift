#if canImport(UIKit)
    import GridCore
    import PhotosCore
    import TimelineCore
    import UIKit

    /// Owns the native accessibility projection for the grid surface.
    ///
    /// The Metal surface stays the hit-testing and gesture owner. This provider exposes only the current
    /// `GridFramePlan.visibleSlots`, in engine order, through stable UID-keyed `UIAccessibilityElement` instances.
    @MainActor
    final class UIKitTimelineGridAccessibilityProvider {
        weak var container: UIView? {
            didSet {
                guard oldValue !== container else { return }
                oldValue?.accessibilityElements = nil
                elementsByUID.removeAll(keepingCapacity: true)
                elements = []
            }
        }
        private var elementsByUID: [PhotoUID: UIKitTimelineGridAccessibilityElement] = [:]
        private(set) var elements: [UIKitTimelineGridAccessibilityElement] = []
        private var invalidationScheduled = false
        private(set) var membershipUpdateCount = 0

        var onOpen: ((PhotoItem) -> Void)?
        var onToggleSelection: ((PhotoItem) -> Void)?

        init(container: UIView) {
            self.container = container
        }

        /// Converts a grid viewport rect through the drawable viewport. The rect is already relative to the
        /// viewport, so using the scroll view as the source would subtract its content offset a second time.
        static func frameInContainer(
            for slot: GridSlot,
            viewport: UIView,
            container: UIView
        ) -> CGRect {
            viewport.convert(slot.viewportRect, to: container)
        }

        func invalidate() {
            guard !invalidationScheduled else { return }
            invalidationScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.invalidationScheduled = false
                self.rebuildFromHost()
            }
        }

        func rebuildFromHost() {
            guard let host = container as? UIKitTimelineGridHostView,
                host.window != nil,
                host.framePump.isActive,
                let plan = host.accessibilityFramePlan()
            else {
                replaceElements([])
                return
            }

            rebuild(
                items: host.accessibilityItems,
                visibleSlots: plan.visibleSlots,
                selectedUIDs: host.selectedUIDs,
                selectionMode: host.selectionMode,
                uploadBadges: host.uploadBadges,
                localizationIdentifier: Self.currentLocalizationIdentifier,
                frameForSlot: { [weak host] slot in
                    guard let host else { return .zero }
                    return Self.frameInContainer(for: slot, viewport: host.metalView, container: host)
                }
            )
        }

        /// Rebuilds the visible projection while retaining an element for every UID that remains visible.
        /// Tests use this seam without constructing Metal or a window-backed host.
        func rebuild(
            items: [PhotoItem],
            visibleSlots: [GridSlot],
            selectedUIDs: Set<PhotoUID>,
            selectionMode: Bool,
            uploadBadges: PendingUploadBadges = .empty,
            localizationIdentifier: String = UIKitTimelineGridAccessibilityProvider.currentLocalizationIdentifier,
            frameForSlot: (GridSlot) -> CGRect
        ) {
            guard let container else {
                replaceElements([])
                return
            }

            let validSlots = visibleSlots.filter { items.indices.contains($0.index) }
            let nextUIDs = validSlots.map { items[$0.index].uid }
            if nextUIDs != elements.map(\.uid) {
                var nextElements: [UIKitTimelineGridAccessibilityElement] = []
                var nextByUID: [PhotoUID: UIKitTimelineGridAccessibilityElement] = [:]
                nextElements.reserveCapacity(validSlots.count)
                for uid in nextUIDs {
                    let element =
                        elementsByUID[uid]
                        ?? UIKitTimelineGridAccessibilityElement(
                            container: container,
                            uid: uid,
                            activate: { [weak self] item, selectionMode in
                                guard let self else { return false }
                                if selectionMode {
                                    self.onToggleSelection?(item)
                                } else {
                                    self.onOpen?(item)
                                }
                                return true
                            })
                    nextElements.append(element)
                    nextByUID[uid] = element
                }
                elementsByUID = nextByUID
                membershipUpdateCount += 1
                replaceElements(nextElements)
            }

            for (slot, element) in zip(validSlots, elements) {
                let item = items[slot.index]
                element.updateFrame(frameForSlot(slot))
                element.updateSemanticsIfNeeded(
                    item: item,
                    selected: selectedUIDs.contains(item.uid),
                    selectionMode: selectionMode,
                    backupState: uploadBadges.accessibilityDescription(for: item.uid),
                    position: slot.index + 1,
                    total: items.count,
                    localizationIdentifier: localizationIdentifier
                )
            }
        }

        static var currentLocalizationIdentifier: String {
            "\(Locale.current.identifier)|\(Bundle.main.preferredLocalizations.joined(separator: ","))"
        }

        private func replaceElements(_ next: [UIKitTimelineGridAccessibilityElement]) {
            elements = next
            container?.accessibilityElements = next
        }
    }

    /// A single native accessibility node for one visible grid item.
    @MainActor
    final class UIKitTimelineGridAccessibilityElement: UIAccessibilityElement {
        let uid: PhotoUID
        private let activateAction: (PhotoItem, Bool) -> Bool
        private var activeItem: PhotoItem?
        private var selectionMode = false
        private var semanticState: SemanticState?
        private(set) var semanticUpdateCount = 0

        private struct SemanticState: Equatable {
            let captureTime: Date
            let isVideo: Bool
            let selected: Bool
            let selectionMode: Bool
            let backupState: String?
            let position: Int
            let total: Int
            let localizationIdentifier: String
        }
        private static let labelFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(
            container: UIView,
            uid: PhotoUID,
            activate: @escaping (PhotoItem, Bool) -> Bool
        ) {
            self.uid = uid
            activateAction = activate
            super.init(accessibilityContainer: container)
        }

        func updateFrame(_ frame: CGRect) {
            accessibilityFrameInContainerSpace = frame
        }

        func updateSemanticsIfNeeded(
            item: PhotoItem,
            selected: Bool,
            selectionMode: Bool,
            backupState: String? = nil,
            position: Int,
            total: Int,
            localizationIdentifier: String
        ) {
            activeItem = item
            self.selectionMode = selectionMode
            let next = SemanticState(
                captureTime: item.captureTime,
                isVideo: item.isVideo,
                selected: selected,
                selectionMode: selectionMode,
                backupState: backupState,
                position: position,
                total: total,
                localizationIdentifier: localizationIdentifier
            )
            guard semanticState != next else { return }
            semanticState = next
            semanticUpdateCount += 1
            Self.labelFormatter.locale = .current
            let kind = L10n.string(item.isVideo ? "a11y.video" : "a11y.photo")
            let label = "\(kind), \(Self.labelFormatter.string(from: item.captureTime))"
            accessibilityLabel = backupState.map { "\(label), \($0)" } ?? label
            accessibilityValue = L10n.string("a11y.grid.position \(position) \(total)")
            accessibilityHint = L10n.string(selectionMode ? "a11y.select_photo_hint" : "a11y.open_photo_hint")
            var traits: UIAccessibilityTraits = [.image, .button]
            if selected { traits.insert(.selected) }
            accessibilityTraits = traits
        }

        override func accessibilityActivate() -> Bool {
            guard let activeItem else { return false }
            return activateAction(activeItem, selectionMode)
        }
    }
#endif
