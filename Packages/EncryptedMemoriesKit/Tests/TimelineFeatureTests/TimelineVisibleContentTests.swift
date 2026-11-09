import AppKit
import Foundation
import GridCore
import MediaByteCache
import MediaCache
import PhotosCore
import SwiftUI
import Testing

@testable import TimelineCore
@testable import TimelineFeature

@MainActor
@Suite(.serialized) struct TimelineVisibleContentTests {
    #if DEBUG
        @Test(.timeLimit(.minutes(1)))
        func productionMacGridKeepsProvisionalPhotoActionsUnwiredUntilQualification() async throws {
            _ = NSApplication.shared
            let items = (0..<60).map { photo("provisional-\($0)", month: 1) }
            let sections = [section(items)]
            let repository = ControlledStartupRepository(cached: nil, remote: sections, provisional: sections)
            let feed = makeVisibleContentFeed()
            let model = TimelineViewModel(repository: repository, feed: feed.feedCore)
            let loading = Task { await model.load() }
            await repository.waitUntilRemoteRequested()
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            var opened: [PhotoUID] = []
            var selections: [Set<PhotoUID>] = []
            let root = NSHostingView(
                rootView: TimelineView(
                    model: model, feed: feed, level: .constant(0), gridProfile: .testRegularTimeline,
                    dragOutProvider: ProvisionalOriginalsProbe(),
                    onSelectionChange: { selections.append($0) }, onOpen: { item, _ in opened.append(item.uid) }))
            window.contentView = root
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func host() -> MetalGridScrollHost? {
                descendants(root).compactMap { $0 as? MetalGridScrollHost }.first
            }
            func waitUntil(_ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                try #require(condition())
            }
            do {
                root.layoutSubtreeIfNeeded()
                try await waitUntil { host()?.coordinator.orderedUIDs.count == 60 }
                let grid = try #require(host())
                try await waitUntil { grid.accessibilityChildren()?.contains { $0 is MetalGridA11yElement } == true }
                #expect(model.isProvisionalPresentation)
                #expect(model.allItems.isEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(grid.onCellClick == nil)
                #expect(grid.onMarqueeBegan == nil)
                #expect(grid.onMarqueeChanged == nil)
                #expect(grid.onMarqueeEnded == nil)
                #expect(grid.onDragOutThreshold == nil)
                let cell = try #require(grid.coordinator.visibleCells().first)
                let point = CGPoint(x: cell.rect.midX, y: cell.rect.midY)
                grid.onCellClick?(point, 2, [])
                grid.onCellClick?(point, 1, .command)
                let element = try #require(
                    grid.accessibilityChildren()?.compactMap { $0 as? MetalGridA11yElement }.first)
                #expect(!element.accessibilityPerformPress())
                #expect(opened.isEmpty, "Provisional mouse and accessibility routes must not open a viewer")
                #expect(selections.isEmpty, "Provisional tiles must not enter selection")
                let clip = try #require(grid.coordinator.clipView)
                let before = clip.bounds.origin
                clip.scroll(to: CGPoint(x: 0, y: before.y > 0 ? 0 : 100))
                #expect(clip.bounds.origin != before, "Provisional rows remain scrollable")
                await repository.releaseRemote()
                await loading.value
                try await waitUntil { host()?.onCellClick != nil && !model.isProvisionalPresentation }
                #expect(host() === grid)
                #expect(model.wholeLibraryInventoryAuthority == .authoritative)
                #expect(Set(model.allItems.map(\.uid)) == Set(items.map(\.uid)))
                #expect(grid.onMarqueeBegan != nil)
                #expect(grid.onMarqueeChanged != nil)
                #expect(grid.onMarqueeEnded != nil)
                #expect(grid.onDragOutThreshold != nil)
                try await waitUntil {
                    grid.accessibilityChildren()?.compactMap { $0 as? MetalGridA11yElement }.first?.onActivate != nil
                }
                let qualified = try #require(grid.coordinator.visibleCells().first)
                let qualifiedPoint = CGPoint(x: qualified.rect.midX, y: qualified.rect.midY)
                let previousOpenCount = opened.count
                grid.onCellClick?(qualifiedPoint, 2, [])
                let qualifiedElement = try #require(
                    grid.accessibilityChildren()?.compactMap { $0 as? MetalGridA11yElement }.first)
                #expect(qualifiedElement.accessibilityPerformPress())
                #expect(opened.count == previousOpenCount + 2)
                let previousSelectionCount = selections.count
                grid.onCellClick?(qualifiedPoint, 1, .command)
                #expect(selections.count == previousSelectionCount + 1)
            } catch {
                model.cancelInitialLoadForTesting()
                await repository.releaseRemote()
                await loading.value
                await feed.stopPrefetch()
                throw error
            }
            await feed.stopPrefetch()
        }
    #endif

    #if DEBUG
        @Test(.timeLimit(.minutes(1)))
        func productionMacGridKeepsTheVisiblePhotoAnchoredAsOlderMetadataPagesArrive() async throws {
            _ = NSApplication.shared
            let items = (0..<180).map { index in
                PhotoItem(
                    uid: PhotoUID(volumeID: "v", nodeID: "page-\(index)"),
                    captureTime: Date(timeIntervalSince1970: Double(index + 1)), mediaType: "image/jpeg")
            }
            let initial = Array(items.suffix(60))
            let repository = ControlledStartupRepository(
                cached: nil, remote: [section(items)], provisional: [section(initial)])
            let feed = makeVisibleContentFeed()
            let model = TimelineViewModel(repository: repository, feed: feed.feedCore)
            let loading = Task { await model.load() }
            await repository.waitUntilRemoteRequested()
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let root = NSHostingView(
                rootView: TimelineView(
                    model: model, feed: feed, level: .constant(0),
                    gridProfile: .testRegularTimeline, onOpen: { _, _ in }))
            window.contentView = root
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func host() -> MetalGridScrollHost? { descendants(root).compactMap { $0 as? MetalGridScrollHost }.first }
            func waitUntil(_ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                try #require(condition())
            }
            do {
                root.layoutSubtreeIfNeeded()
                try await waitUntil { host()?.coordinator.orderedUIDs.count == 60 }
                let grid = try #require(host())
                grid.scrollToItem(initial[24].uid)
                let anchor = try #require(grid.currentScrollAnchor())
                let clip = try #require(grid.coordinator.clipView)
                try #require(clip.bounds.minY > 0, "SETUP: an interior scroll position")
                for count in [120, 180] {
                    let known = Array(items.suffix(count))
                    await repository.publishProvisional([section(known)])
                    try await waitUntil { grid.coordinator.orderedUIDs.count == count }
                    let after = try #require(grid.currentScrollAnchor())
                    #expect(after.itemID == anchor.itemID, "Growing metadata keeps the same photo below the top bar")
                    #expect(abs(after.topOffset - anchor.topOffset) < 0.5, "Growing metadata keeps its viewport offset")
                    #expect(Set(grid.coordinator.orderedUIDs) == Set(known.map(\.uid)))
                    #expect(model.allItems.isEmpty)
                    #expect(model.currentSections.isEmpty, "Provisional rows do not enter suggestion inventories")
                    #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                    #expect(grid.onCellClick == nil)
                }
                await repository.releaseRemote()
                await loading.value
                try await waitUntil { grid.onCellClick != nil }
                let completed = try #require(grid.currentScrollAnchor())
                #expect(completed.itemID == anchor.itemID)
                #expect(abs(completed.topOffset - anchor.topOffset) < 0.5)
                #expect(Set(model.allItems.map(\.uid)) == Set(items.map(\.uid)))
                #expect(model.wholeLibraryInventoryAuthority == .authoritative)
            } catch {
                model.cancelInitialLoadForTesting()
                await repository.releaseRemote()
                await loading.value
                await feed.stopPrefetch()
                throw error
            }
            await feed.stopPrefetch()
        }
    #endif

    #if DEBUG
        @Test(.timeLimit(.minutes(1)))
        func aLaterPageFailureReplacesTheNativeGridAndRetryStartsWithOnlyNewRows() async throws {
            _ = NSApplication.shared
            let failedItems = (0..<10).map { photo("failed-\($0)", month: 1) }
            let retryItems = (0..<10).map { photo("retry-\($0)", month: 1) }
            let repository = RetryingProvisionalRepository(first: [section(failedItems)], second: [section(retryItems)])
            let feed = makeVisibleContentFeed()
            let model = TimelineViewModel(repository: repository, feed: feed.feedCore)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let root = NSHostingView(rootView: TimelineView(model: model, feed: feed))
            window.contentView = root
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func host() -> MetalGridScrollHost? { descendants(root).compactMap { $0 as? MetalGridScrollHost }.first }
            func waitUntil(_ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while ContinuousClock.now < deadline {
                    root.layoutSubtreeIfNeeded()
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(
                    condition(),
                    "C7 state: \(model.initialLibraryLoadState), host: \(host() != nil), root: \(root.bounds)")
            }
            let loading = Task { await model.load() }
            var retry: Task<Void, Never>?
            do {
                try await waitUntil { model.isProvisionalPresentation && host() != nil }
                // This C7 probe starts after a presentable frame; C5 tests the frame-readiness boundary separately.
                model.markInitialContentReady()
                #expect(model.initialLibraryLoadState.isContentReady)
                #expect(Set(model.gridItems.map(\.uid)) == Set(failedItems.map(\.uid)))
                #expect(model.isProvisionalPresentation)
                #expect(!model.initialLibraryLoadState.hasSettled)
                await repository.release(read: 1)
                await loading.value
                #expect(model.gridItems.isEmpty)
                #expect(model.currentSections.isEmpty)
                #expect(model.allItems.isEmpty)
                #expect(!model.isProvisionalPresentation)
                #expect(model.initialLibraryLoadState.failure?.retryable == true)
                #expect(model.initialLibraryChangeToken == "")
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(!model.initialLibraryLoadState.isCompletelyEmpty)
                if case .failed(_, retryable: true) = model.gridState {
                } else {
                    Issue.record("The existing error cover replaces the provisional grid")
                }
                try await waitUntil { host() == nil }
                let next = Task { await model.retry() }
                retry = next
                try await waitUntil { model.isProvisionalPresentation && host() != nil }
                #expect(model.initialLibraryLoadState.failure == nil, "Retry removes the previous failure cover")
                #expect(model.initialLibraryLoadState.knownCount == 10)
                #expect(!model.initialLibraryLoadState.hasSettled)
                #expect(Set(model.gridItems.map(\.uid)) == Set(retryItems.map(\.uid)))
                #expect(Set(model.gridItems.map(\.uid)).isDisjoint(with: Set(failedItems.map(\.uid))))
                #expect(model.allItems.isEmpty)
                #expect(model.currentSections.isEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(await repository.readCount == 2)
                await repository.release(read: 2)
                await next.value
                #expect(Set(model.allItems.map(\.uid)) == Set(retryItems.map(\.uid)))
                #expect(model.wholeLibraryInventoryAuthority == .authoritative)
                #expect(model.initialLibraryChangeToken == "retry-complete")
            } catch {
                model.cancelInitialLoadForTesting()
                retry?.cancel()
                await repository.release(read: 1)
                await repository.release(read: 2)
                await loading.value
                await retry?.value
                await feed.stopPrefetch()
                throw error
            }
            await feed.stopPrefetch()
        }
    #endif

    @Test func mapPresentationAndLibraryHaveOppositeOrderWithoutChangingCanonicalItems() async {
        let old = photo("old", month: 1)
        let new = photo("new", month: 2)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [[section([old, new])]]),
            feed: makeVisibleContentFeed().feedCore)
        await model.load()
        #expect(model.presentationItems.map(\.uid) == [old.uid, new.uid])
        await model.showTransientItems([old, new], sectionID: "cluster")
        #expect(model.allItems.map(\.uid) == [old.uid, new.uid])
        #expect(model.presentationItems.map(\.uid) == [new.uid, old.uid])
        await model.select(.all)
        #expect(model.presentationItems.map(\.uid) == [old.uid, new.uid])
    }

    @Test(arguments: [
        PhotoFilter.tag(.favorites), .tag(.videos), .tag(.motionPhotos), .trash,
        .album(id: "album", title: "Album"), .sharedAlbum(volumeID: "volume", nodeID: "node", title: "Shared"),
    ])
    func collectionsKeepNewestFirstEvenWhenTheyContainTheWholeLibrary(filter: PhotoFilter) async {
        let old = photo("old", month: 1)
        let new = photo("new", month: 2)
        let sections = [section([old, new])]
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [sections]), feed: makeVisibleContentFeed().feedCore,
            library: VisibleContentLibrary(timelines: [filter: [sections]]))
        await model.load()
        await model.select(filter)
        #expect(model.presentationItems.map(\.uid) == [new.uid, old.uid])
        #expect(model.allItems.map(\.uid) == [old.uid, new.uid])
        await model.select(.all)
        #expect(model.presentationItems.map(\.uid) == [old.uid, new.uid])
    }

    @Test func favoriteContextInvalidatesCachedSearchResult() async {
        let item = photo("favorite-candidate", month: 1)
        let sections = [section([item])]
        let withoutFavorite = TimelineSearchProjection(
            key: TimelineSearchProjectionKey(
                sourceRevision: 1,
                query: "favorites",
                context: TimelineSearchContext(),
                semanticMatches: nil
            ),
            sections: sections
        )
        let withFavorite = TimelineSearchProjection(
            key: TimelineSearchProjectionKey(
                sourceRevision: 1,
                query: "favorites",
                context: TimelineSearchContext(favoriteUIDs: [item.uid]),
                semanticMatches: nil
            ),
            sections: sections
        )
        #expect(withoutFavorite.snapshot.isEmpty)
        #expect(withFavorite.snapshot.items.map(\.uid) == [item.uid])
    }

    @Test func stateReloadInvalidatesCachedSearchResult() async {
        let old = photo("old-item", month: 1)
        let new = photo("new-item", month: 1)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [
                [section([old])],
                [section([new])],
            ]),
            feed: makeVisibleContentFeed().feedCore
        )
        await model.load()

        let coordinator = TimelineSearchProjectionCoordinator()
        let beforeKey = TimelineSearchProjectionKey(
            sourceRevision: model.contentRevision,
            query: "new-item",
            context: TimelineSearchContext(),
            semanticMatches: nil
        )
        let beforeReload = await coordinator.resolve(sections: model.currentSections, key: beforeKey)
        #expect(beforeReload?.snapshot.isEmpty == true)

        _ = await model.refreshLibrary()
        let afterKey = TimelineSearchProjectionKey(
            sourceRevision: model.contentRevision,
            query: "new-item",
            context: TimelineSearchContext(),
            semanticMatches: nil
        )
        let afterReload = await coordinator.resolve(sections: model.currentSections, key: afterKey)
        #expect(afterReload?.snapshot.items.map(\.uid) == [new.uid])
    }

    @Test func monthMarkersAreOnlyDerivedWhenRequested() async {
        let january = photo("jan", month: 1)
        let february = photo("feb", month: 2)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [[section([january, february])]]),
            feed: makeVisibleContentFeed().feedCore
        )
        await model.load()

        let revision = model.contentRevision
        let markers = MetalGridProductionAdapter.dateMarkers(items: model.allItems, granularity: .month)
        #expect(markers.map(\.index) == [0, 1])
        #expect(model.allItems.map(\.uid) == [january.uid, february.uid])
        #expect(
            model.contentRevision == revision,
            "deriving optional month markers must not mutate the Metal data source")
    }

    @Test func changedMiddleItemAdvancesExactGridRevision() async {
        let a = photo("a", month: 1)
        let b = photo("b", month: 2)
        let c = photo("c", month: 3)
        let replacement = photo("replacement", month: 2)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [
                [section([a, b, c])],
                [section([a, replacement, c])],
            ]),
            feed: makeVisibleContentFeed().feedCore
        )
        await model.load()

        let beforeItems = model.allItems
        let beforeRevision = model.contentRevision
        _ = await model.refreshLibrary()
        let afterItems = model.allItems

        #expect(beforeItems.map(\.uid) == [a.uid, b.uid, c.uid])
        #expect(afterItems.map(\.uid) == [a.uid, replacement.uid, c.uid])
        #expect(model.contentRevision != beforeRevision)
    }

    @Test func cachedFilterRouteIsShownImmediatelyWhileRefreshing() async {
        let oldFavorite = photo("old-favorite", month: 1)
        let newFavorite = photo("new-favorite", month: 1)
        let all = photo("all", month: 1)
        let favoriteFilter = PhotoFilter.tag(.favorites)
        let library = VisibleContentLibrary(
            timelines: [
                favoriteFilter: [
                    [section([oldFavorite])],
                    [section([newFavorite])],
                ]
            ],
            delayAfterFirstRequest: [favoriteFilter: .milliseconds(120)]
        )
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [[section([all])]]),
            feed: makeVisibleContentFeed().feedCore,
            library: library
        )

        await model.select(favoriteFilter)
        #expect(model.allItems.map(\.uid) == [oldFavorite.uid])

        await model.select(.all)
        #expect(model.allItems.map(\.uid) == [all.uid])

        let refresh = Task { await model.select(favoriteFilter) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.allItems.map(\.uid) == [oldFavorite.uid])

        await refresh.value
        #expect(model.allItems.map(\.uid) == [newFavorite.uid])
    }

    @Test func slowAllLoadDoesNotClobberSelectedFilter() async {
        let all = photo("all-after-delay", month: 1)
        let favorite = photo("favorite-selected", month: 1)
        let favoriteFilter = PhotoFilter.tag(.favorites)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(
                timelines: [[section([all])]],
                cachedDelay: .milliseconds(120)
            ),
            feed: makeVisibleContentFeed().feedCore,
            library: VisibleContentLibrary(timelines: [favoriteFilter: [[section([favorite])]]])
        )

        let initialAllLoad = Task { await model.load() }
        try? await Task.sleep(for: .milliseconds(20))

        await model.select(favoriteFilter)
        await initialAllLoad.value

        #expect(model.allItems.map(\.uid) == [favorite.uid])
        #expect(model.currentSections.flatMap(\.items).map(\.uid) == [favorite.uid])
    }

    @Test func renderedCachedTimelineIsPresentableWhileAuthoritativeRefreshContinues() async {
        let cached = photo("cached", month: 1)
        let remote = photo("remote", month: 1)
        let repository = ControlledStartupRepository(
            cached: [section([cached])],
            remote: [section([remote])]
        )
        let model = TimelineViewModel(
            repository: repository,
            feed: makeVisibleContentFeed().feedCore
        )

        let load = Task { await model.load() }
        await repository.waitUntilRemoteRequested()
        let concurrentLoad = Task { await model.load() }

        #expect(model.allItems.map(\.uid) == [cached.uid])
        #expect(model.initialLibraryLoadState == .loadingContent(count: 1, usingCachedInventory: true))
        model.markInitialContentReady()
        #expect(
            model.initialLibraryLoadState == .contentReady(count: 1),
            "a fully rendered non-empty cache must not wait behind network validation")

        await repository.releaseRemote()
        await load.value
        await concurrentLoad.value
        #expect(model.initialLibraryLoadState == .contentReady(count: 1))
        #expect(model.allItems.map(\.uid) == [remote.uid])
        #expect(
            await repository.remoteRequestCount == 1,
            "transient duplicate SwiftUI hosts must share one authoritative startup request")
    }

    @Test func cachedEmptyTimelineWaitsForAuthoritativeNonemptyViewport() async {
        let remote = photo("remote-after-empty", month: 1)
        let repository = ControlledStartupRepository(
            cached: [],
            remote: [section([remote])]
        )
        let model = TimelineViewModel(repository: repository, feed: makeVisibleContentFeed().feedCore)

        let load = Task { await model.load() }
        await repository.waitUntilRemoteRequested()

        #expect(model.initialLibraryLoadState == .validatingCachedContent(count: 0))
        guard case .loading = model.gridState else {
            Issue.record("An unvalidated empty cache must show loading, never the empty screen")
            await repository.releaseRemote()
            await load.value
            return
        }
        model.markInitialContentReady()
        #expect(
            model.initialLibraryLoadState == .validatingCachedContent(count: 0),
            "an empty cache has no viewport that can prove the remote library is empty")

        await repository.releaseRemote()
        await load.value
        #expect(model.allItems.map(\.uid) == [remote.uid])
        #expect(model.initialLibraryLoadState == .loadingContent(count: 1, usingCachedInventory: false))

        model.markInitialContentReady()
        #expect(model.initialLibraryLoadState == .contentReady(count: 1))
    }

    @Test func firstPagePendingCannotShowAnEmptyLibrary() async {
        let remote = photo("first-page", month: 1)
        let repository = ControlledStartupRepository(cached: nil, remote: [section([remote])])
        let model = TimelineViewModel(repository: repository, feed: makeVisibleContentFeed().feedCore)
        let load = Task { await model.load() }
        await repository.waitUntilRemoteRequested()
        #expect(model.initialLibraryLoadState == .preparingInventory)
        #expect(model.initialLibraryLoadState.knownCount == nil)
        if case .loading = model.gridState {} else { Issue.record("The first page has not arrived") }
        await repository.releaseRemote()
        await load.value
        #expect(!model.initialLibraryLoadState.isEmpty)
        #expect(model.allItems.map(\.uid) == [remote.uid])
    }

    @Test func successfulEmptyAccountCanFillLaterWithoutStayingEmpty() async {
        let remote = photo("later-upload", month: 1)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [[], [section([remote])]]),
            feed: makeVisibleContentFeed().feedCore
        )
        await model.load()
        #expect(model.initialLibraryLoadState.isCompletelyEmpty)
        if case .empty = model.gridState {} else { Issue.record("A successful empty listing must settle") }
        _ = await model.refreshLibrary()
        #expect(model.allItems.map(\.uid) == [remote.uid])
        if case .loaded = model.gridState {} else { Issue.record("Known photos must replace the empty screen") }
    }

    @Test(arguments: [false, true])
    func failedFirstReadNeverShowsEmptyEvenWithAnEmptyCache(hasCache: Bool) async {
        let model = TimelineViewModel(
            repository: FailedEmptyStartupRepository(hasCache: hasCache), feed: makeVisibleContentFeed().feedCore
        )
        await model.load()
        #expect(model.initialLibraryLoadState.failure != nil)
        #expect(!model.initialLibraryLoadState.isCompletelyEmpty)
        if case .failed = model.gridState {} else { Issue.record("A failed first listing must show failure") }
    }

    @Test func backendCancellationOfAnActiveFirstReadShowsFailure() async {
        for hasCache in [false, true] {
            let model = TimelineViewModel(
                repository: FailedEmptyStartupRepository(hasCache: hasCache, cancelled: true),
                feed: makeVisibleContentFeed().feedCore
            )
            await model.load()
            #expect(model.initialLibraryLoadState.failure != nil)
            #expect(!model.initialLibraryLoadState.isCompletelyEmpty)
            if case .failed = model.gridState {
            } else {
                Issue.record("An active cancelled first listing must show failure")
            }
        }
    }

    @Test func metadataEnrichmentDoesNotRebuildUnchangedWholeLibraryGrid() async {
        let cached = photo("same", month: 1)
        let enriched = PhotoItem(
            uid: cached.uid,
            captureTime: cached.captureTime,
            mediaType: cached.mediaType,
            tags: [.favorites],
            burstMemberIDs: ["same", "burst-peer"]
        )
        let repository = MetadataStartupRepository(cached: [section([cached])], remote: [section([enriched])])
        let enrichedModel = TimelineViewModel(repository: repository, feed: makeVisibleContentFeed().feedCore)

        await enrichedModel.load()

        #expect(enrichedModel.allItems == [enriched])
        #expect(enrichedModel.contentRevision == 2)
        #expect(enrichedModel.wholeLibraryRevision == 1)
        #expect(enrichedModel.wholeLibraryContentRevision == 2)
        #expect(
            enrichedModel.gridSourceRevision == 4,
            "same UID order must keep the already-rendered Metal grid generation")
    }

    @Test func matchingValidationTokenSkipsAuthoritativeStartupEnumeration() async {
        let cached = photo("cached-stable", month: 1)
        let repository = ValidatedStartupRepository(
            cached: [section([cached])],
            remote: [section([photo("should-not-load", month: 2)])],
            persistedToken: "event-7",
            currentToken: "event-7"
        )
        let model = TimelineViewModel(repository: repository, feed: makeVisibleContentFeed().feedCore)

        await model.load()

        #expect(model.initialLibraryLoadState == .loadingContent(count: 1, usingCachedInventory: false))
        model.markInitialContentReady()
        #expect(model.initialLibraryLoadState == .contentReady(count: 1))
        #expect(model.allItems.map(\.uid) == [cached.uid])
        #expect(model.initialLibraryChangeToken == "event-7")
        #expect(await repository.remoteRequestCount == 0)
    }

    @Test func changedValidationTokenPerformsExactlyOneAuthoritativeLoad() async {
        let cached = photo("cached-stale", month: 1)
        let remote = photo("remote-current", month: 2)
        let repository = ValidatedStartupRepository(
            cached: [section([cached])],
            remote: [section([remote])],
            persistedToken: "event-7",
            currentToken: "event-8"
        )
        let model = TimelineViewModel(repository: repository, feed: makeVisibleContentFeed().feedCore)

        await model.load()

        #expect(model.allItems.map(\.uid) == [remote.uid])
        #expect(model.initialLibraryChangeToken == "event-8")
        #expect(await repository.remoteRequestCount == 1)
    }

    @Test func pendingPhotosShowOnlyInTheWholeLibraryGrid() async {
        let remote = photo("remote", month: 1)
        let model = TimelineViewModel(
            repository: MetadataStartupRepository(cached: [], remote: [section([remote])]),
            feed: makeVisibleContentFeed().feedCore)
        await model.load()
        let canonicalRevision = model.gridSourceRevision
        #expect(canonicalRevision % 4 == 0)

        let local = PhotoItem(
            uid: PhotoUID(localPending: .photoLibrary, identifier: "asset"), captureTime: Self.date(2026, 2, 1),
            mediaType: "image/jpeg")
        model.setPendingPresentation(
            PendingTimelinePresentation(
                revision: 1, membershipRevision: 1, snapshot: TimelineSnapshot(sections: [section([remote, local])]),
                localUIDs: [local.uid], favoriteIntents: [:],
                uploadBadges: PendingUploadBadges(base: [local.uid: .waiting]),
                isCanonical: false))

        #expect(model.gridItems.map(\.uid) == [remote.uid, local.uid])
        #expect(model.allItems.map(\.uid) == [remote.uid], "remote-only consumers keep the Proton timeline")
        #expect(model.gridSourceRevision == 6)
        #expect(model.pendingUploadBadges[local.uid] == .waiting)

        await model.select(.trash)
        #expect(!model.showsPendingPhotos)
        #expect(model.gridSourceRevision % 4 == 1)
        #expect(model.pendingUploadBadges.isEmpty)
    }

    @Test func aLibraryWithoutProtonPhotosStillShowsPendingPhotos() async {
        let model = TimelineViewModel(
            repository: MetadataStartupRepository(cached: [], remote: []), feed: makeVisibleContentFeed().feedCore)
        await model.load()
        guard case .empty = model.state else {
            Issue.record("expected an empty Proton library")
            return
        }
        let local = PhotoItem(
            uid: PhotoUID(localPending: .photoLibrary, identifier: "asset"), captureTime: Self.date(2026, 2, 1),
            mediaType: "image/jpeg")
        model.setPendingPresentation(
            PendingTimelinePresentation(
                revision: 1, membershipRevision: 1, snapshot: TimelineSnapshot(sections: [section([local])]),
                localUIDs: [local.uid], favoriteIntents: [:], uploadBadges: .empty, isCanonical: false))

        guard case .loaded(let sections) = model.gridState else {
            Issue.record("pending photos must show")
            return
        }
        #expect(sections.flatMap(\.items).map(\.uid) == [local.uid])
    }

    private func photo(_ id: String, month: Int) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Self.date(2026, month, 1),
            mediaType: "image/jpeg"
        )
    }

    private func section(_ items: [PhotoItem]) -> TimelineSection {
        TimelineSection(id: "visible-content", date: items.first?.captureTime ?? .distantPast, title: "", items: items)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

@MainActor private func makeVisibleContentFeed() -> ThumbnailFeed {
    let namespace = "tests-visible-content-\(UUID().uuidString)"
    let root = timelineFeatureTestCacheRoot("visible")
    return ThumbnailFeed(
        cache: ThumbnailCache(namespace: namespace, rootDirectory: root), loader: VisibleContentThumbnailLoader())
}

private final class VisibleContentRepository: PhotosRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var timelines: [[TimelineSection]]
    private let cachedDelay: Duration?

    init(timelines: [[TimelineSection]], cachedDelay: Duration? = nil) {
        self.timelines = timelines
        self.cachedDelay = cachedDelay
    }

    func loadTimeline() async throws -> [TimelineSection] {
        return lock.withLock {
            if timelines.count > 1 {
                return timelines.removeFirst()
            }
            return timelines.first ?? []
        }
    }

    func cachedTimeline() async -> [TimelineSection]? {
        if let cachedDelay {
            try? await Task.sleep(for: cachedDelay)
        }
        return nil
    }
}

private actor ControlledStartupRepository: PhotosRepository {
    private let cached: [TimelineSection]?
    private let remote: [TimelineSection]
    private let provisional: [TimelineSection]?
    private var provisionalObserver: (@Sendable (ProvisionalTimelineSnapshot) async -> Void)?
    private var remoteRequested = false
    private(set) var remoteRequestCount = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(cached: [TimelineSection]?, remote: [TimelineSection], provisional: [TimelineSection]? = nil) {
        self.cached = cached
        self.remote = remote
        self.provisional = provisional
    }

    func loadTimelineSnapshot(
        onProvisional: @escaping @Sendable (ProvisionalTimelineSnapshot) async -> Void
    ) async throws -> TimelineLoadSnapshot {
        provisionalObserver = onProvisional
        defer { provisionalObserver = nil }
        if let provisional { await onProvisional(ProvisionalTimelineSnapshot(sections: provisional)) }
        return TimelineLoadSnapshot(sections: try await loadTimeline(), validationToken: nil)
    }

    func cachedTimeline() async -> [TimelineSection]? { cached }

    func loadTimeline() async throws -> [TimelineSection] {
        remoteRequested = true
        remoteRequestCount += 1
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll(keepingCapacity: false)
        await withCheckedContinuation { releaseContinuation = $0 }
        return remote
    }

    func waitUntilRemoteRequested() async {
        guard !remoteRequested else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func publishProvisional(_ sections: [TimelineSection]) async {
        await provisionalObserver?(ProvisionalTimelineSnapshot(sections: sections))
    }

    func releaseRemote() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct MetadataStartupRepository: PhotosRepository {
    let cached: [TimelineSection]
    let remote: [TimelineSection]

    func cachedTimeline() async -> [TimelineSection]? { cached }
    func loadTimeline() async throws -> [TimelineSection] { remote }
}

private actor ValidatedStartupRepository: PhotosRepository, LibraryChangeTokenProvider {
    let cached: [TimelineSection]
    let remote: [TimelineSection]
    private var persistedToken: String
    private let currentToken: String
    private(set) var remoteRequestCount = 0

    init(
        cached: [TimelineSection],
        remote: [TimelineSection],
        persistedToken: String,
        currentToken: String
    ) {
        self.cached = cached
        self.remote = remote
        self.persistedToken = persistedToken
        self.currentToken = currentToken
    }

    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        CachedTimelineSnapshot(sections: cached, validationToken: persistedToken)
    }

    func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }

    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        remoteRequestCount += 1
        persistedToken = currentToken
        return TimelineLoadSnapshot(sections: remote, validationToken: currentToken)
    }

    func libraryChangeToken() async throws -> String { currentToken }
}

private actor VisibleContentLibrary: PhotoLibraryProvider {
    private var timelines: [PhotoFilter: [[TimelineSection]]]
    private let delayAfterFirstRequest: [PhotoFilter: Duration]
    private var requestCounts: [PhotoFilter: Int] = [:]

    init(
        timelines: [PhotoFilter: [[TimelineSection]]],
        delayAfterFirstRequest: [PhotoFilter: Duration] = [:]
    ) {
        self.timelines = timelines
        self.delayAfterFirstRequest = delayAfterFirstRequest
    }

    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        let count = requestCounts[filter, default: 0]
        requestCounts[filter] = count + 1
        if count > 0, let delay = delayAfterFirstRequest[filter] {
            try? await Task.sleep(for: delay)
        }
        var sequence = timelines[filter] ?? []
        if sequence.count > 1 {
            let next = sequence.removeFirst()
            timelines[filter] = sequence
            return next
        }
        return sequence.first ?? []
    }
}

private actor VisibleContentThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

private struct FailedEmptyStartupRepository: PhotosRepository {
    enum Failure: Error { case firstRead }
    let hasCache: Bool
    var cancelled = false
    func cachedTimeline() async -> [TimelineSection]? { hasCache ? [] : nil }
    func loadTimeline() async throws -> [TimelineSection] {
        if cancelled { throw CancellationError() }
        throw Failure.firstRead
    }
}

private struct ProvisionalOriginalsProbe: OriginalFileProvider {
    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        throw CocoaError(.fileReadNoSuchFile)
    }
}

private actor RetryingProvisionalRepository: PhotosRepository {
    let first: [TimelineSection]
    let second: [TimelineSection]
    private(set) var readCount = 0
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(first: [TimelineSection], second: [TimelineSection]) {
        self.first = first
        self.second = second
    }

    func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }
    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        try await loadTimelineSnapshot(onProvisional: { _ in })
    }

    func loadTimelineSnapshot(
        onProvisional: @escaping @Sendable (ProvisionalTimelineSnapshot) async -> Void
    ) async throws -> TimelineLoadSnapshot {
        readCount += 1
        let read = readCount
        let sections = read == 1 ? first : second
        await onProvisional(ProvisionalTimelineSnapshot(sections: sections))
        if !released.contains(read) { await withCheckedContinuation { waiters[read] = $0 } }
        try Task.checkCancellation()
        if read == 1 { throw URLError(.networkConnectionLost) }
        return TimelineLoadSnapshot(sections: sections, validationToken: "retry-complete")
    }

    func release(read: Int) {
        released.insert(read)
        waiters.removeValue(forKey: read)?.resume()
    }
}
