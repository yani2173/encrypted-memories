import GridCore
import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import Testing
import TimelineCore
import TimelineUIKitAdapter
import UIKit
import UploadCore

@testable import TimelineUIKitFeature

@MainActor
@Suite("UIKit grid host missing tiles")
struct UIKitTimelineMissingTilesTests {
    private func uid(_ name: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: name) }

    private func makeHost(_ tiles: [PhotoUID]) -> UIKitTimelineGridHostView {
        let host = UIKitTimelineGridHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.itemIndexByUID = Dictionary(uniqueKeysWithValues: tiles.enumerated().map { ($1, $0) })
        return host
    }

    @Test func missingTilesKeepOnlyTheNonResidentOnesNewestFirst() {
        let tiles = ["a", "b", "c", "d"].map(uid)
        let host = makeHost(tiles)

        let missing = host.missingRetryableTiles(in: tiles, isResident: { $0 == tiles[1] })

        #expect(missing.uids == [tiles[3], tiles[2], tiles[0]])
    }

    @Test func theOrderFollowsTheLibraryIndexNotTheGivenOrder() {
        let tiles = ["a", "b", "c"].map(uid)
        let host = makeHost(tiles)

        let missing = host.missingRetryableTiles(in: [tiles[1], tiles[2], tiles[0]], isResident: { _ in false })

        #expect(missing.uids == [tiles[2], tiles[1], tiles[0]])
    }

    @Test func noMissingTileLeavesAnEmptyResult() {
        let tiles = ["a", "b"].map(uid)
        let host = makeHost(tiles)

        let missing = host.missingRetryableTiles(in: tiles, isResident: { _ in true })

        #expect(missing.uids.isEmpty)
        #expect(missing.ramReady == 0)
    }

    @Test func loadingTilesShareOneBoundedSweepAndReduceMotionIsStatic() {
        let tiles = [uid("first"), uid("second")]
        let host = makeHost(tiles)
        host.setPlaceholderReduceMotion(false)
        host.updatePlaceholderPulse(visibleUIDs: [tiles[0]], isResident: { _ in false }, now: 0)
        #expect(host.placeholderIsAnimating)
        host.updatePlaceholderPulse(visibleUIDs: tiles, isResident: { _ in false }, now: 3)
        #expect(host.placeholderIsAnimating)
        host.updatePlaceholderPulse(visibleUIDs: tiles, isResident: { _ in false }, now: 5)
        #expect(!host.placeholderIsAnimating)
        host.updatePlaceholderPulse(visibleUIDs: tiles, isResident: { _ in false }, now: 50)
        #expect(!host.placeholderIsAnimating)
        host.updatePlaceholderPulse(visibleUIDs: [], isResident: { _ in false }, now: 51)
        host.setPlaceholderReduceMotion(true)
        host.updatePlaceholderPulse(visibleUIDs: tiles, isResident: { _ in false }, now: 52)
        #expect(!host.placeholderIsAnimating)
    }

    @Test func residentAndUnknownTilesNeverAnimateAsPlaceholders() {
        let id = uid("known")
        let host = makeHost([id])
        host.setPlaceholderReduceMotion(false)
        host.updatePlaceholderPulse(visibleUIDs: [id, uid("unknown")], isResident: { $0 == id }, now: 0)
        #expect(!host.placeholderIsAnimating)
    }

    @Test(arguments: [false, true])
    func scrollingRestartsTheBoundedSweepOnlyAfterNewLoadingTilesSettle(decelerates: Bool) throws {
        let items = (0..<180).map {
            PhotoItem(
                uid: uid("scroll-\($0)"), captureTime: Date(timeIntervalSince1970: Double($0)), mediaType: "image/jpeg")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let host = UIKitTimelineGridHostView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            displayLink: UIKitTimelineDisplayLinkDriver(), renderFrame: { .drawn(hasPendingWork: false) })
        let window = UIWindow(frame: host.bounds)
        window.addSubview(host)
        window.isHidden = false
        defer {
            host.setActive(false)
            host.removeFromSuperview()
            window.isHidden = true
        }
        host.configure(items: items, thumbnailFeed: feed, initialViewportPlacement: .oldest)
        host.layoutIfNeeded()
        host.setPlaceholderReduceMotion(false)
        func visible() throws -> [PhotoUID] {
            let plan = try #require(host.accessibilityFramePlan())
            return plan.visibleSlots.map { items[$0.index].uid }
        }
        func update(_ time: Double) throws {
            host.updatePlaceholderPulse(visibleUIDs: try visible(), isResident: { _ in false }, now: time)
        }
        let initial = Set(try visible())
        try #require(!initial.isEmpty)
        try update(0)
        try update(5)
        #expect(!host.placeholderIsAnimating)
        host.scrollViewWillBeginDragging(host.scrollView)
        host.scrollView.setContentOffset(CGPoint(x: 0, y: 1_200), animated: false)
        try #require(!Set(try visible()).subtracting(initial).isEmpty, "SETUP: scrolling reveals new photos")
        host.scrollViewDidEndDragging(host.scrollView, willDecelerate: decelerates)
        if decelerates {
            try update(10)
            #expect(!host.placeholderIsAnimating, "The sweep waits until deceleration ends")
            host.scrollViewDidEndDecelerating(host.scrollView)
        }
        try update(10)
        #expect(host.placeholderIsAnimating, "The real scroll-end route restarts for newly visible loading tiles")
        try update(15)
        #expect(!host.placeholderIsAnimating, "The new sweep keeps the existing duration bound")
        host.scrollViewDidEndDecelerating(host.scrollView)
        try update(16)
        #expect(!host.placeholderIsAnimating, "A repeated end notification cannot restart the same sweep")
        host.scrollViewWillBeginDragging(host.scrollView)
        host.scrollViewDidEndDragging(host.scrollView, willDecelerate: false)
        try update(17)
        #expect(!host.placeholderIsAnimating, "A gesture that reveals no new tiles cannot restart the sweep")
        host.setPlaceholderReduceMotion(true)
        host.scrollViewWillBeginDragging(host.scrollView)
        let previous = Set(try visible())
        host.scrollView.setContentOffset(CGPoint(x: 0, y: 2_400), animated: false)
        try #require(!Set(try visible()).subtracting(previous).isEmpty)
        host.scrollViewDidEndDragging(host.scrollView, willDecelerate: false)
        try update(18)
        #expect(!host.placeholderIsAnimating, "Reduce Motion remains static after new tiles settle")
        host.setPlaceholderReduceMotion(false)
        let beforeJump = Set(try visible())
        host.scrollToLatest(animated: false)
        try #require(!Set(try visible()).subtracting(beforeJump).isEmpty)
        try update(19)
        #expect(host.placeholderIsAnimating, "An explicit jump also ends on newly visible loading tiles")
        try update(24)
        #expect(!host.placeholderIsAnimating)
    }

    @Test func theSweepRestartsWhenTheGridBecomesActiveAgain() {
        let id = uid("restart")
        let host = makeHost([id])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        defer {
            host.removeFromSuperview()
            window.isHidden = true
        }
        host.setPlaceholderReduceMotion(false)
        host.updatePlaceholderPulse(visibleUIDs: [id], isResident: { _ in false }, now: 0)
        #expect(host.placeholderIsAnimating)
        host.setActive(false)
        host.setActive(true)
        host.updatePlaceholderPulse(visibleUIDs: [id], isResident: { _ in false }, now: 100)
        #expect(host.placeholderIsAnimating)
        host.updatePlaceholderPulse(visibleUIDs: [id], isResident: { _ in false }, now: 105)
        #expect(!host.placeholderIsAnimating)
    }

    @Test func readinessRejectsFailedFramesAndInactiveOrReplacedSources() async {
        let id = uid("known")
        let host = makeHost([id])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        defer {
            host.removeFromSuperview()
            window.isHidden = true
        }
        var callbacks = 0
        host.onFirstContentReady = { callbacks += 1 }
        func drain() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        host.reportFirstRenderedContent(visibleUIDs: [id], isResident: { _ in true }, frameEncoded: false)
        await drain()
        #expect(callbacks == 0)
        // The pump goes inactive without invalidating the pending callback, so only the second active check
        // inside the deferred block can refuse it.
        host.reportFirstRenderedContent(visibleUIDs: [id], isResident: { _ in true }, frameEncoded: true)
        host.framePump.setActive(false)
        await drain()
        #expect(callbacks == 0)
        host.framePump.setActive(true)
        host.reportFirstRenderedContent(visibleUIDs: [id], isResident: { _ in true }, frameEncoded: true)
        host.invalidateFirstContentForSource()
        await drain()
        #expect(callbacks == 0)
        host.reportFirstRenderedContent(visibleUIDs: [id], isResident: { _ in true }, frameEncoded: true)
        await drain()
        #expect(callbacks == 1)
    }

    @Test func onlyAFrameWithALoadedThumbnailReportsReadyAndALaterFailureStillSurfaces() async {
        let tiles = [uid("loading"), uid("loaded")]
        let host = makeHost(tiles)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        defer {
            host.removeFromSuperview()
            window.isHidden = true
        }
        var state = LibraryLoadState.loadingContent(count: 2, usingCachedInventory: false)
        var callbacks = 0
        host.onFirstContentReady = {
            callbacks += 1
            state = LibraryLoadPolicy.reduce(state, .firstContentReady)
        }
        func drain() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        host.reportFirstRenderedContent(visibleUIDs: tiles, isResident: { _ in false }, frameEncoded: true)
        await drain()
        #expect(callbacks == 0)
        state = LibraryLoadPolicy.reduce(state, .contentLoadFailed(message: "offline"))
        #expect(state == .failed(message: "offline", retryable: true))

        state = .loadingContent(count: 2, usingCachedInventory: false)
        host.reportFirstRenderedContent(visibleUIDs: tiles, isResident: { $0 == tiles[1] }, frameEncoded: true)
        host.reportFirstRenderedContent(visibleUIDs: tiles, isResident: { $0 == tiles[1] }, frameEncoded: true)
        await drain()
        #expect(callbacks == 1)
        #expect(state == .contentReady(count: 2))
    }

    @Test func sameUIDRevisionCannotAcknowledgeAnEarlierFrame() async {
        let id = uid("same")
        let item = PhotoItem(uid: id, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let host = UIKitTimelineGridHostView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            displayLink: UIKitTimelineDisplayLinkDriver(), renderFrame: { .drawn(hasPendingWork: false) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        defer {
            host.removeFromSuperview()
            window.isHidden = true
        }
        host.configure(items: [item], contentRevision: 1, thumbnailFeed: feed)
        var callbacks = 0
        host.onFirstContentReady = { callbacks += 1 }
        host.reportFirstRenderedContent(visibleUIDs: [id], isResident: { _ in true }, frameEncoded: true)
        host.configure(items: [item], contentRevision: 2, thumbnailFeed: feed)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(callbacks == 0)
        host.reportFirstRenderedContent(visibleUIDs: [id], isResident: { _ in true }, frameEncoded: true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(callbacks == 1)
        host.configure(items: [item], contentRevision: 3, thumbnailFeed: feed)
        host.reportFirstRenderedContent(visibleUIDs: [id], isResident: { _ in true }, frameEncoded: true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(callbacks == 1)
    }

    @Test func aNewItemOrderMustReportItsOwnFirstFrame() async {
        let first = PhotoItem(uid: uid("one"), captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
        let second = PhotoItem(uid: uid("two"), captureTime: Date(timeIntervalSince1970: 2), mediaType: "image/jpeg")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let host = UIKitTimelineGridHostView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            displayLink: UIKitTimelineDisplayLinkDriver(), renderFrame: { .drawn(hasPendingWork: false) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        defer {
            host.removeFromSuperview()
            window.isHidden = true
        }
        var callbacks = 0
        host.onFirstContentReady = { callbacks += 1 }
        func report(_ item: PhotoItem) async {
            host.reportFirstRenderedContent(visibleUIDs: [item.uid], isResident: { _ in true }, frameEncoded: true)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        host.configure(items: [first], contentRevision: 1, thumbnailFeed: feed)
        await report(first)
        await report(first)
        #expect(callbacks == 1)
        host.configure(items: [first, second], contentRevision: 2, thumbnailFeed: feed)
        await report(second)
        #expect(callbacks == 2)
    }

    @Test func refreshedImageEpochCannotAcknowledgeAnEarlierFrame() async {
        let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "epoch")
        let item = PhotoItem(uid: key.localUID, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
        let tile = PendingTile(
            key: key, item: item, revision: UploadBackupRevision(rawValue: 1), handoff: nil,
            isSettled: false, badge: .waiting, displayName: "epoch")
        let presenter = PendingTimelinePresenter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            presenter.onChange = { presentation in
                guard presentation.localUIDs.contains(item.uid) else { return }
                presenter.onChange = nil
                continuation.resume()
            }
            presenter.setPending(PendingBackupSnapshot(membershipRevision: 1, tiles: [tile]), enabled: true)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let host = UIKitTimelineGridHostView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            displayLink: UIKitTimelineDisplayLinkDriver(), renderFrame: { .drawn(hasPendingWork: false) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        defer {
            host.removeFromSuperview()
            window.isHidden = true
        }
        host.configure(items: [item], contentRevision: 1, thumbnailFeed: feed)
        var callbacks = 0
        host.onFirstContentReady = { callbacks += 1 }
        host.reportFirstRenderedContent(visibleUIDs: [item.uid], isResident: { _ in true }, frameEncoded: true)
        presenter.noteContentRefreshed([item.uid])
        host.configure(
            items: [item], contentRevision: 1, thumbnailFeed: feed, uploadBadges: presenter.current.uploadBadges)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(callbacks == 0)
        host.reportFirstRenderedContent(visibleUIDs: [item.uid], isResident: { _ in true }, frameEncoded: true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(callbacks == 1)
        presenter.noteContentRefreshed([item.uid])
        host.configure(
            items: [item], contentRevision: 1, thumbnailFeed: feed, uploadBadges: presenter.current.uploadBadges)
        host.reportFirstRenderedContent(visibleUIDs: [item.uid], isResident: { _ in true }, frameEncoded: true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(callbacks == 1)
    }
}
