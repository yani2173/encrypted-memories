import CoreGraphics
import Foundation
import GridCore
import PhotosCore
import Testing
import TimelineCore

@testable import TimelineFeature

private func uids(_ n: Int) -> [PhotoUID] { (0..<n).map { PhotoUID(volumeID: "v", nodeID: "\($0)") } }

@MainActor
@Suite struct MetalGridSelectionControllerTests {
    @Test func singleClickReplaces() {
        let u = uids(10)
        let c = MetalGridSelectionController()
        c.click(flatIndex: 3, uid: u[3], orderedUIDs: u, modifiers: [], selectionMode: false)
        #expect(c.selected == [u[3]])
        c.click(flatIndex: 5, uid: u[5], orderedUIDs: u, modifiers: [], selectionMode: false)
        #expect(c.selected == [u[5]])  // replaces, not adds
    }

    @Test func cmdClickToggles() {
        let u = uids(10)
        let c = MetalGridSelectionController()
        c.click(flatIndex: 3, uid: u[3], orderedUIDs: u, modifiers: .command, selectionMode: false)
        c.click(flatIndex: 6, uid: u[6], orderedUIDs: u, modifiers: .command, selectionMode: false)
        #expect(c.selected == [u[3], u[6]])
        c.click(flatIndex: 3, uid: u[3], orderedUIDs: u, modifiers: .command, selectionMode: false)
        #expect(c.selected == [u[6]])  // toggled off
    }

    @Test func shiftClickSelectsRange() {
        let u = uids(10)
        let c = MetalGridSelectionController()
        c.click(flatIndex: 2, uid: u[2], orderedUIDs: u, modifiers: [], selectionMode: false)  // anchor
        c.click(flatIndex: 5, uid: u[5], orderedUIDs: u, modifiers: .shift, selectionMode: false)
        #expect(c.selected == Set(u[2...5]))
    }

    @Test func backgroundClickClears() {
        let u = uids(4)
        let c = MetalGridSelectionController()
        c.click(flatIndex: 1, uid: u[1], orderedUIDs: u, modifiers: [], selectionMode: false)
        c.clickBackground()
        #expect(c.selected.isEmpty)
    }

    @Test func onChangeFires() {
        let u = uids(4)
        let c = MetalGridSelectionController()
        var last: Set<PhotoUID> = []
        c.onChange = { last = $0 }
        c.click(flatIndex: 2, uid: u[2], orderedUIDs: u, modifiers: [], selectionMode: false)
        #expect(last == [u[2]])
    }
}

@Suite struct MetalGridViewerHandoffTests {
    @Test func doubleClickOpensViewer_singleDoesNot() {
        #expect(GridInteractionPolicy.decision(click: .double).opensViewer == true)
        #expect(GridInteractionPolicy.decision(click: .single).opensViewer == false)
    }

    @Test func handoffResolvesCorrectItem() {
        let items = (0..<5).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let clicked = items[3].uid
        // The exact mapping MetalGridInteractionController.onOpen uses to hand off to the viewer.
        #expect(items.first { $0.uid == clicked } == items[3])
    }
}

@MainActor
@Suite struct MetalGridAccessibilityTests {
    @Test func labelStatesKindAndDate() {
        let video = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "1"), captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "video/quicktime")
        let photo = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "2"), captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/jpeg")
        // Kind labels are localized via the package catalog; assert against the resolved value so the
        // test is locale-independent (e.g. German "Foto" vs English "Photo").
        #expect(MetalGridAccessibilityProvider.label(for: video).hasPrefix(L10n.string("a11y.video") + ", "))
        #expect(MetalGridAccessibilityProvider.label(for: photo).hasPrefix(L10n.string("a11y.photo") + ", "))
    }

    @Test func labelOfAWaitingPhotoSaysThatTheBackupIsPaused() {
        let waiting = PhotoItem(
            uid: PhotoUID(localPending: .photoLibrary, identifier: "asset"),
            captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/heic")
        let badges = PendingUploadBadges(base: [waiting.uid: .waiting], isPaused: true)
        let label = MetalGridAccessibilityProvider.label(
            for: waiting, backupState: badges.accessibilityDescription(for: waiting.uid))
        #expect(
            label == MetalGridAccessibilityProvider.label(for: waiting) + ", " + L10n.string("a11y.upload_badge.paused")
        )
        #expect(
            MetalGridAccessibilityProvider.label(
                for: waiting, backupState: badges.replacing(isPaused: false).accessibilityDescription(for: waiting.uid))
                == MetalGridAccessibilityProvider.label(for: waiting))
    }

    @Test func labelsRebuildWhenAPhotoChangesItsBadgeDuringThePause() {
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "asset")
        let running = PendingUploadBadges(base: [uid: .waiting])
        let paused = running.replacing(isPaused: true)
        let finished = PendingUploadBadges(base: [uid: .done], isPaused: true)
        #expect(MetalGridAccessibilityProvider.badgesChangeLabels(from: running, to: paused))
        #expect(MetalGridAccessibilityProvider.badgesChangeLabels(from: paused, to: running))
        #expect(
            MetalGridAccessibilityProvider.badgesChangeLabels(from: paused, to: finished),
            "the finished photo no longer says that the backup is paused")
        #expect(!MetalGridAccessibilityProvider.badgesChangeLabels(from: paused, to: paused))
        #expect(
            !MetalGridAccessibilityProvider.badgesChangeLabels(
                from: running, to: running.replacing(progress: [uid: 4])),
            "progress without a pause leaves the labels alone")
    }
}
