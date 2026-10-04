import MediaByteCache
import MediaCache
import PhotosCore
import TimelineCore
import XCTest

@testable import TimelineFeature

final class UploadRefreshAndInteractionTests: XCTestCase {
    @MainActor
    func testManualRefreshReloadsAndDeduplicatesTimeline() async {
        let old = photo("old", seconds: 1)
        let new = photo("new", seconds: 2)
        let repository = RefreshRepository(timelines: [
            [section([old])],
            [section([old, new, new])],
        ])
        let model = TimelineViewModel(repository: repository, feed: makeFeed().feedCore)

        await model.load()
        XCTAssertEqual(model.allItems.map(\.uid), [old.uid])
        let initialRevision = model.wholeLibraryRevision

        let result = await model.refreshLibrary()
        XCTAssertEqual(result.timelineCountBefore, 1)
        XCTAssertEqual(result.timelineCountAfter, 2)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.addedUIDs, [new.uid])
        XCTAssertEqual(model.allItems.map(\.uid), [old.uid, new.uid])
        XCTAssertEqual(model.wholeLibraryUIDs, [old.uid, new.uid])
        XCTAssertEqual(model.wholeLibraryRevision, initialRevision + 1)
        XCTAssertEqual(repository.loadCount, 2)
    }

    @MainActor
    func testRefreshAfterUploadFindsUploadedUID() async {
        let uploaded = photo("uploaded", seconds: 2)
        let repository = RefreshRepository(timelines: [
            [section([])],
            [section([uploaded])],
        ])
        let model = TimelineViewModel(repository: repository, feed: makeFeed().feedCore)

        await model.load()
        let result = await model.refreshAfterUpload(uploadedUID: uploaded.uid)

        XCTAssertTrue(result.found)
        XCTAssertEqual(result.foundItem?.uid, uploaded.uid)
        XCTAssertEqual(result.filterDescription, "all")
        XCTAssertEqual(result.addedUIDs, [uploaded.uid])
    }

    func testTimelineContentUnchangedHelper() {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let sections = [section([a, b])]
        // Identical flattened content is unchanged.
        XCTAssertTrue(TimelineViewModel.timelineContentUnchanged(sections, vs: [a, b]))
        // A different count, a reorder, a removed item, or an appended item changes the result.
        XCTAssertFalse(TimelineViewModel.timelineContentUnchanged(sections, vs: [a]))
        XCTAssertFalse(TimelineViewModel.timelineContentUnchanged(sections, vs: [b, a]))
        XCTAssertFalse(TimelineViewModel.timelineContentUnchanged(sections, vs: [a, b, photo("c", seconds: 3)]))
        // The same items regrouped into two sections still flatten to an equal result.
        XCTAssertTrue(TimelineViewModel.timelineContentUnchanged([section([a]), section([b])], vs: [a, b]))
    }

    @MainActor
    func testUnchangedAllRefreshDoesNotReassignOrRestartPrefetch() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let repository = RefreshRepository(timelines: [[section([a, b])], [section([a, b])]])
        let model = TimelineViewModel(repository: repository, feed: makeFeed().feedCore)
        await model.load()

        PhotoDiagnostics.shared.resetForTests()
        let result = await model.refreshLibrary()  // fresh content identical to what's shown

        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.unchangedSkip"), 1)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.applied"), 0)
        XCTAssertEqual(result.timelineCountBefore, 2)
        XCTAssertEqual(result.timelineCountAfter, 2)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid, b.uid])
    }

    @MainActor
    func testChangedAllRefreshAppliesExactlyOnce() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let repository = RefreshRepository(timelines: [[section([a])], [section([a, b])]])
        let model = TimelineViewModel(repository: repository, feed: makeFeed().feedCore)
        await model.load()

        PhotoDiagnostics.shared.resetForTests()
        let result = await model.refreshLibrary()  // content changed (b appeared)

        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.applied"), 1)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.unchangedSkip"), 0)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid, b.uid])
        XCTAssertEqual(result.addedUIDs, [b.uid])
    }

    @MainActor
    func testFirstAuthoritativeInventoryDoesNotReportWholeLibraryAsNew() async {
        let a = photo("a", seconds: 1)
        let model = TimelineViewModel(
            repository: RefreshRepository(timelines: [[section([a])]]),
            feed: makeFeed().feedCore
        )

        await model.load()

        XCTAssertEqual(model.takeInitialAuthoritativeAddedUIDs(), [])
    }

    @MainActor
    func testAllRevisitUsesSessionSnapshotNotDiskReload() async {
        let a = photo("a", seconds: 1)
        let repository = RefreshRepository(timelines: [[section([a])]])
        let library = FakeLibrary(sections: [section([photo("raw", seconds: 5)])])
        let model = TimelineViewModel(repository: repository, feed: makeFeed().feedCore, library: library)
        await model.load()
        XCTAssertEqual(repository.cachedCount, 1)  // first visit consulted the on-disk cache once
        let wholeLibraryUIDs = model.wholeLibraryUIDs
        let wholeLibraryRevision = model.wholeLibraryRevision

        await model.select(.tag(.raw))  // leave All Photos
        XCTAssertEqual(model.wholeLibraryUIDs, wholeLibraryUIDs)
        XCTAssertEqual(model.wholeLibraryRevision, wholeLibraryRevision)
        PhotoDiagnostics.shared.resetForTests()
        await model.select(.all)  // return to All Photos

        // The revisit shows the in-memory snapshot instantly - it must not re-read the on-disk cache.
        XCTAssertEqual(repository.cachedCount, 1)
        XCTAssertGreaterThanOrEqual(PhotoDiagnostics.shared.counter("timeline.refresh.snapshotHit"), 1)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid])
    }

    @MainActor
    func testSlowAllRefreshDoesNotClobberSelectedFilteredRoute() async {
        let a = photo("a", seconds: 1)
        let rawItem = photo("raw", seconds: 5)
        let repository = RefreshRepository(timelines: [[section([a])], [section([a])]])
        let library = FakeLibrary(sections: [section([rawItem])])
        let model = TimelineViewModel(repository: repository, feed: makeFeed().feedCore, library: library)
        await model.load()

        // Kick a slow `.all` refresh, then switch to a filtered route before it finishes; the stale `.all`
        // result must not overwrite the newly-selected route.
        repository.loadDelayMs = 120
        async let refresh: Void = { _ = await model.refreshLibrary() }()
        await model.select(.tag(.raw))
        _ = await refresh

        XCTAssertEqual(model.filter, .tag(.raw))
        XCTAssertEqual(model.allItems.map(\.uid), [rawItem.uid])  // filtered route intact, not clobbered by All
    }

    func testUploadRefreshRetryScheduleStartsFastAndStaysBounded() {
        let schedule = TimelineRefreshRetrySchedule.uploadDefault

        XCTAssertEqual(schedule.delays.first, .zero, "the first refresh runs without any delay")
        // A locally created photo must not wait seconds for its first retry.
        XCTAssertLessThanOrEqual(schedule.delays[1], .milliseconds(400))
        let untilTwoSeconds = schedule.delays.prefix { $0 <= .seconds(2) }
        XCTAssertGreaterThanOrEqual(
            untilTwoSeconds.count, 4, "the grid retries several times inside the first seconds")
        XCTAssertEqual(
            schedule.delays.sorted(), schedule.delays, "delays grow monotonically into the long tail")
        let total = schedule.delays.reduce(Duration.zero, +)
        XCTAssertLessThanOrEqual(total, .seconds(35), "the whole convergence window stays bounded")
    }

    @MainActor
    func testPendingInventoryVisibilityIsExposedAsRetryableConvergence() async {
        let model = TimelineViewModel(repository: PendingVisibilityRepository(), feed: makeFeed().feedCore)

        let result = await model.refreshLibrary()

        XCTAssertEqual(result.failureReason, .pendingInventoryVisibility)
        XCTAssertNotNil(result.errorMessage)
    }

    @MainActor
    func testGenuineRefreshFailureRemainsTerminal() async {
        let model = TimelineViewModel(repository: TerminalFailureRepository(), feed: makeFeed().feedCore)

        let result = await model.refreshLibrary()

        XCTAssertEqual(result.failureReason, .other)
        XCTAssertEqual(result.errorMessage, "terminal refresh failure")
    }

    @MainActor
    func testScopeLossDuringRefreshRequestsBackendRecovery() async {
        let model = TimelineViewModel(repository: ScopeLossRepository(), feed: makeFeed().feedCore)

        let result = await model.refreshLibrary()

        XCTAssertEqual(result.failureReason, .scopeAccessLost)
    }

    @MainActor
    func testScopeLossAfterUploadDoesNotWarmTheRetiredThumbnailFeed() async {
        let loader = RecordingThumbnailLoader()
        let feed = makeFeed(loader: loader)
        let uploadedUID = PhotoUID(volumeID: "scope-volume", nodeID: "scope-upload")
        let model = TimelineViewModel(repository: ScopeLossRepository(), feed: feed.feedCore)

        let result = await model.refreshAfterUpload(uploadedUID: uploadedUID)
        await feed.stopPrefetch()
        let status = await feed.prefetchStatus()
        let loaderRequestCount = await loader.requestCount

        XCTAssertEqual(result.failureReason, .scopeAccessLost)
        XCTAssertEqual(status.currentQueueLength, 0)
        XCTAssertEqual(status.activeJobs, 0)
        XCTAssertEqual(status.downloadStarted, 0)
        XCTAssertEqual(loaderRequestCount, 0)
    }

    @MainActor
    func testFilteredRefreshRoutesPreserveTypedScopeLoss() async {
        let filters: [PhotoFilter] = [
            .tag(.raw),
            .album(id: "scope-album", title: "Scope Album"),
            .trash,
        ]

        for filter in filters {
            let model = TimelineViewModel(
                repository: RefreshRepository(timelines: [[section([])]]),
                feed: makeFeed().feedCore,
                library: ScopeLossLibrary()
            )
            await model.load()
            await model.select(filter)

            let result = await model.refreshLibrary()

            XCTAssertEqual(result.failureReason, .scopeAccessLost, "route: \(filter)")
        }
    }

    @MainActor
    func testScopeLossDuringInitialLoadIsExposedToHost() async {
        let model = TimelineViewModel(repository: ScopeLossRepository(), feed: makeFeed().feedCore)

        await model.load()

        XCTAssertEqual(model.initialLoadFailureReason, .scopeAccessLost)
    }

    @MainActor
    func testMapProjectionUsesWholeLibraryIndexAcrossRouteMutations() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let c = photo("c", seconds: 3)
        let all = [section([a, b, c])]
        let model = TimelineViewModel(
            repository: RefreshRepository(timelines: [all]),
            feed: makeFeed().feedCore,
            library: FakeLibrary(sections: [section([c])])
        )
        await model.load()
        await model.select(.tag(.raw))

        XCTAssertEqual(model.allItems.map(\.uid), [c.uid])
        XCTAssertEqual(model.allLibraryItems(matching: [b.uid, a.uid]).map(\.uid), [a.uid, b.uid])
        XCTAssertEqual(model.allLibraryItem(matching: b.uid), b)

        await model.commitTrash([b])
        XCTAssertEqual(model.allLibraryItems(matching: [a.uid, b.uid, c.uid]).map(\.uid), [a.uid, c.uid])

        await model.commitRestore([b])
        XCTAssertEqual(model.wholeLibraryItemsForViewer.map(\.uid), [a.uid, b.uid, c.uid])
    }

    @MainActor
    func testOverlappingTrashAndRestoreBothReachTheLibrary() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let c = photo("c", seconds: 3)
        let all = [section([a, b, c])]
        let model = TimelineViewModel(
            repository: RefreshRepository(timelines: [all]),
            feed: makeFeed().feedCore,
            library: FakeLibrary(sections: all)
        )
        await model.load()
        await model.commitTrash([b])
        for _ in 0..<20 {
            // The person trashes one photo and restores another before the first change is shown.
            async let trashed: Void = model.commitTrash([c])
            async let restored: Void = model.commitRestore([b])
            _ = await (trashed, restored)
            XCTAssertEqual(model.wholeLibraryUIDs, [a.uid, b.uid], "an earlier change must not overwrite a later one")
            await model.commitRestore([c])
            await model.commitTrash([b])
        }
    }

    @MainActor
    func testTrashFromAlbumUpdatesWholeLibraryAndRejectsStaleRefreshes() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let stale = [section([a, b])]
        let model = TimelineViewModel(
            repository: RefreshRepository(timelines: [stale, stale]),
            feed: makeFeed().feedCore,
            library: FakeLibrary(sections: stale)
        )
        await model.load()
        await model.select(.album(id: "album", title: "Album"))

        await model.commitTrash([b])
        XCTAssertEqual(model.wholeLibraryUIDs, [a.uid])

        await model.select(.all)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid], "a stale All Photos response must not resurrect trash")
        await model.select(.album(id: "album", title: "Album"))
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid], "cached and freshly loaded album routes must agree")
    }

    @MainActor
    func testRestoreReinsertsAllPhotosAndSuppressesStaleTrashResponse() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let stale = [section([a, b])]
        let model = TimelineViewModel(
            repository: RefreshRepository(timelines: [stale, stale]),
            feed: makeFeed().feedCore,
            library: FakeLibrary(sections: stale)
        )
        await model.load()
        await model.commitTrash([b])
        await model.select(.trash)

        await model.commitRestore([b])
        XCTAssertFalse(model.allItems.contains { $0.uid == b.uid })
        XCTAssertEqual(model.wholeLibraryUIDs, [a.uid, b.uid])

        await model.select(.all)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid, b.uid])
        await model.select(.trash)
        XCTAssertFalse(model.allItems.contains { $0.uid == b.uid }, "a stale Trash response must not resurrect restore")
    }

    @MainActor
    func testInFlightFilteredLoadCannotResurrectCommittedTrash() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let stale = [section([a, b])]
        let model = TimelineViewModel(
            repository: RefreshRepository(timelines: [stale]),
            feed: makeFeed().feedCore,
            library: FakeLibrary(sections: stale, delay: .milliseconds(120))
        )
        await model.load()

        let switchRoute = Task { await model.select(.tag(.raw)) }
        try? await Task.sleep(for: .milliseconds(20))
        await model.commitTrash([b])
        await switchRoute.value

        XCTAssertEqual(model.allItems.map(\.uid), [a.uid])
    }

    @MainActor
    func testTrashByIdentityHidesAPhotoThatNoListingShowedYet() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let model = TimelineViewModel(
            repository: RefreshRepository(timelines: [[section([a])], [section([a, b])]]),
            feed: makeFeed().feedCore
        )
        await model.load()

        await model.commitTrash(uids: [b.uid])
        await model.refreshLibrary()

        XCTAssertEqual(model.allItems.map(\.uid), [a.uid], "a later listing must not show the trashed photo")
    }

    func testSingleClickSelectsAndDoesNotOpenViewer() {
        let decision = GridInteractionPolicy.decision(click: .single, selectionMode: false)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .replace)
    }

    func testDoubleClickOpensViewer() {
        let decision = GridInteractionPolicy.decision(click: .double, selectionMode: false)
        XCTAssertTrue(decision.opensViewer)
        XCTAssertEqual(decision.selection, .none)
    }

    func testCmdClickTogglesSelection() {
        let decision = GridInteractionPolicy.decision(click: .single, modifiers: .command, selectionMode: false)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .toggle)
    }

    func testShiftClickRangeSelects() {
        let decision = GridInteractionPolicy.decision(click: .single, modifiers: .shift, selectionMode: false)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .range)
    }

    func testSelectionModeSingleClickTogglesSelection() {
        let decision = GridInteractionPolicy.decision(click: .single, selectionMode: true)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .toggle)
    }

    func testDoubleClickOpensViewerEvenInSelectionMode() {
        let decision = GridInteractionPolicy.decision(click: .double, selectionMode: true)
        XCTAssertTrue(decision.opensViewer)
    }
}

@MainActor private func makeFeed(
    loader: any ThumbnailBatchLoader = EmptyThumbnailLoader()
) -> ThumbnailFeed {
    let namespace = "tests-refresh-\(UUID().uuidString)"
    let root = timelineFeatureTestCacheRoot("upload-refresh")
    return ThumbnailFeed(
        cache: ThumbnailCache(namespace: namespace, rootDirectory: root), loader: loader)
}

private func photo(_ id: String, seconds: TimeInterval) -> PhotoItem {
    PhotoItem(
        uid: PhotoUID(volumeID: "vol", nodeID: id),
        captureTime: Date(timeIntervalSince1970: seconds),
        mediaType: "image/jpeg")
}

private func section(_ items: [PhotoItem]) -> TimelineSection {
    TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)
}

private final class RefreshRepository: PhotosRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var timelines: [[TimelineSection]]
    private var _loadCount = 0
    private var _cachedCount = 0
    private var _loadDelayMs = 0

    init(timelines: [[TimelineSection]]) {
        self.timelines = timelines
    }

    func loadTimeline() async throws -> [TimelineSection] {
        let delay = lock.withLock { _loadDelayMs }
        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
        return lock.withLock {
            _loadCount += 1
            if timelines.count > 1 {
                return timelines.removeFirst()
            }
            return timelines.first ?? []
        }
    }

    func cachedTimeline() async -> [TimelineSection]? {
        lock.withLock { _cachedCount += 1 }
        return nil
    }

    var loadCount: Int { lock.withLock { _loadCount } }
    var cachedCount: Int { lock.withLock { _cachedCount } }
    var loadDelayMs: Int {
        get { lock.withLock { _loadDelayMs } }
        set { lock.withLock { _loadDelayMs = newValue } }
    }
}

private struct PendingVisibilityRepository: PhotosRepository {
    func loadTimeline() async throws -> [TimelineSection] {
        throw PendingVisibilityError()
    }
}

private struct PendingVisibilityError: LocalizedError, TimelineInventoryConvergenceError {
    var errorDescription: String? { "inventory is still converging" }
}

private struct TerminalFailureRepository: PhotosRepository {
    func loadTimeline() async throws -> [TimelineSection] {
        throw TerminalRefreshError()
    }
}

private struct TerminalRefreshError: LocalizedError {
    var errorDescription: String? { "terminal refresh failure" }
}

private struct ScopeLossRepository: PhotosRepository {
    func loadTimeline() async throws -> [TimelineSection] {
        throw ScopeLossError()
    }
}

private struct ScopeLossError: LibraryChangeTerminalError {}

private struct ScopeLossLibrary: PhotoLibraryProvider {
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        throw ScopeLossError()
    }
}

private final class FakeLibrary: PhotoLibraryProvider, @unchecked Sendable {
    private let sections: [TimelineSection]
    private let delay: Duration?
    init(sections: [TimelineSection], delay: Duration? = nil) {
        self.sections = sections
        self.delay = delay
    }
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        if let delay { try await Task.sleep(for: delay) }
        return sections
    }
}

private actor EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

private actor RecordingThumbnailLoader: ThumbnailBatchLoader {
    private(set) var requestCount = 0

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requestCount += uids.count
        return .delivered
    }
}
