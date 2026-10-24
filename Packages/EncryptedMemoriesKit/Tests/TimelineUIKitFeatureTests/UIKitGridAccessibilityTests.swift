#if canImport(UIKit)
    import GridCore
    import PhotosCore
    import Testing
    import TimelineCore
    import UIKit
    @testable import TimelineUIKitFeature

    @MainActor
    @Suite("UIKit grid accessibility")
    struct UIKitGridAccessibilityTests {
        private func item(_ index: Int, video: Bool = false) -> PhotoItem {
            PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: "node-\(index)"),
                captureTime: Date(timeIntervalSince1970: TimeInterval(index)),
                mediaType: video ? "video/quicktime" : "image/jpeg"
            )
        }

        private func slot(_ index: Int, x: CGFloat, y: CGFloat = 0) -> GridSlot {
            let rect = CGRect(x: x, y: y, width: 80, height: 80)
            return GridSlot(
                index: index,
                section: 0,
                item: index,
                column: index,
                row: 0,
                slotRect: rect,
                viewportRect: rect
            )
        }

        @Test func visibleElementsKeepStableUIDOrderAndIdentity() {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
            let provider = UIKitTimelineGridAccessibilityProvider(container: container)
            let items = (0..<4).map { item($0) }

            provider.rebuild(
                items: items,
                visibleSlots: [slot(2, x: 0), slot(0, x: 90)],
                selectedUIDs: [],
                selectionMode: false,
                frameForSlot: \.viewportRect
            )
            let first = provider.elements

            #expect(first.map(\.uid) == [items[2].uid, items[0].uid])
            #expect(container.accessibilityElements?.count == 2)

            provider.rebuild(
                items: items,
                visibleSlots: [slot(0, x: 0), slot(2, x: 90)],
                selectedUIDs: [],
                selectionMode: false,
                frameForSlot: \.viewportRect
            )

            #expect(ObjectIdentifier(provider.elements[0]) == ObjectIdentifier(first[1]))
            #expect(ObjectIdentifier(provider.elements[1]) == ObjectIdentifier(first[0]))
            #expect(provider.elements.map(\.uid) == [items[0].uid, items[2].uid])
        }

        @Test func visibleElementsExposeLabelsTraitsAndSelectionAction() {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
            let provider = UIKitTimelineGridAccessibilityProvider(container: container)
            let photo = item(0)
            let video = item(1, video: true)
            var opened: PhotoUID?
            var toggled: PhotoUID?
            provider.onOpen = { opened = $0.uid }
            provider.onToggleSelection = { toggled = $0.uid }

            provider.rebuild(
                items: [photo, video],
                visibleSlots: [slot(0, x: 0)],
                selectedUIDs: [photo.uid],
                selectionMode: false,
                frameForSlot: \.viewportRect
            )
            let normal = provider.elements[0]
            #expect(normal.accessibilityLabel?.hasPrefix(L10n.string("a11y.photo")) == true)
            #expect(normal.accessibilityValue == L10n.string("a11y.grid.position 1 2"))
            #expect(normal.accessibilityTraits.contains(.image))
            #expect(normal.accessibilityTraits.contains(.button))
            #expect(normal.accessibilityTraits.contains(.selected))
            #expect(normal.accessibilityActivate())
            #expect(opened == photo.uid)

            provider.rebuild(
                items: [photo, video],
                visibleSlots: [slot(1, x: 0)],
                selectedUIDs: [],
                selectionMode: true,
                frameForSlot: \.viewportRect
            )
            let selection = provider.elements[0]
            #expect(selection.accessibilityLabel?.hasPrefix(L10n.string("a11y.video")) == true)
            #expect(selection.accessibilityValue == L10n.string("a11y.grid.position 2 2"))
            #expect(selection.accessibilityHint == L10n.string("a11y.select_photo_hint"))
            #expect(selection.accessibilityActivate())
            #expect(toggled == video.uid)
        }

        @Test func aWaitingPhotoSaysThatTheBackupIsPaused() {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
            let provider = UIKitTimelineGridAccessibilityProvider(container: container)
            let waiting = PhotoItem(
                uid: PhotoUID(localPending: .photoLibrary, identifier: "asset"),
                captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/heic")
            let paused = PendingUploadBadges(base: [waiting.uid: .waiting], isPaused: true)
            let rebuild = { (badges: PendingUploadBadges) in
                provider.rebuild(
                    items: [waiting], visibleSlots: [slot(0, x: 0)], selectedUIDs: [], selectionMode: false,
                    uploadBadges: badges, frameForSlot: \.viewportRect)
            }

            rebuild(paused)
            let element = provider.elements[0]
            #expect(element.accessibilityLabel?.hasSuffix(", \(L10n.string("a11y.upload_badge.paused"))") == true)

            rebuild(paused.replacing(isPaused: false))
            #expect(provider.elements[0] === element)
            #expect(element.accessibilityLabel?.contains(L10n.string("a11y.upload_badge.paused")) == false)
        }

        @Test func viewportFrameDoesNotApplyScrollOffsetTwice() {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            let viewport = UIView(frame: CGRect(x: 4, y: 7, width: 300, height: 400))
            let scrollView = UIScrollView(frame: viewport.frame)
            scrollView.contentSize = CGSize(width: 300, height: 4_000)
            scrollView.contentOffset = CGPoint(x: 0, y: 900)
            container.addSubview(viewport)
            container.addSubview(scrollView)
            let visibleSlot = slot(0, x: 10, y: 20)

            let frame = UIKitTimelineGridAccessibilityProvider.frameInContainer(
                for: visibleSlot,
                viewport: viewport,
                container: container
            )

            #expect(frame == CGRect(x: 14, y: 27, width: 80, height: 80))
        }
    }
#endif
