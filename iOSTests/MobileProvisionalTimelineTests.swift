import AlbumCore
import Foundation
import GridCore
import LibrarySourceRuntime
import MLSearchCore
import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import ProtonAuth
import SwiftUI
import Testing
import TimelineCore
import UIKit

@testable import EncryptedMemoriesMobile
@testable import ProtonDriveBackend
@testable import TimelineUIKitFeature

@MainActor @Suite(.serialized) struct MobileProvisionalTimelineTests {
    @Test(.timeLimit(.minutes(1)))
    func knownRowsReachOnlyTheGridBeforeTheCompleteQualifiedLoad() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let items = Array(fixture.items.prefix(10))
        #expect(items.count == 10)
        let repository = MobileHeldProvisionalRepository(items: items)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [], thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.setApplicationActive(false)
        let runtime = await installRuntime(into: model, fixture: fixture)
        let loading = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: repository) }
        do {
            try #require(await repository.waitForPage(), "SETUP: the listing reached its held second page")
            let expected = Set(items.map(\.uid))
            #expect(Set(model.gridItems.map(\.uid)) == expected, "Known rows reach the grid before completion")
            #expect(model.gridItems.count == 10, "The count contains known photos only")
            #expect(model.loadState.knownCount == 10)
            #expect(model.items.isEmpty, "Provisional rows cannot replace the business inventory")
            #expect(model.selectedItems(expected).isEmpty, "Provisional rows cannot become a selection")
            #expect(model.isolatedInventoryAuthorityForTesting == .hydrating)
            #expect(!model.isCompletelyEmpty)
            #expect(!model.allowsAutomaticSuggestionRefresh)
            model.markFirstContentReady()
            #expect(model.loadState.isContentReady, "A known-photo placeholder frame can reveal the grid")
            #expect(!model.loadState.hasSettled, "A drawn placeholder does not finish the listing")
            #expect(model.items.isEmpty)
            #expect(model.isolatedInventoryAuthorityForTesting == .hydrating)
            await repository.release()
            try await loading.value
            #expect(Set(model.gridItems.map(\.uid)) == expected)
            #expect(Set(model.items.map(\.uid)) == expected)
            #expect(Set(model.selectedItems(expected).map(\.uid)) == expected)
            #expect(model.isolatedInventoryAuthorityForTesting == .authoritative)
            model.markFirstContentReady()
            #expect(model.loadState.hasSettled)
        } catch {
            loading.cancel()
            await repository.release()
            _ = await loading.result
            await runtime.shutdown()
            await fixture.feed.stopPrefetch()
            throw error
        }
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func productionScreenLeavesActionsUnwiredUntilQualification() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let items = Array(fixture.items.prefix(10))
        let repository = MobileHeldProvisionalRepository(items: items)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [], thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.setApplicationActive(false)
        let runtime = await installRuntime(into: model, fixture: fixture)
        let screen = try mountScreen(model: model)
        let window = screen.window
        defer { screen.close() }
        let loading = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: repository) }
        do {
            try #require(await repository.waitForPage())
            try await waitUntil {
                descendants(window).contains { ($0 as? UIKitTimelineGridHostView)?.itemUIDs.count == 10 }
            }
            let host = try #require(descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.first)
            #expect(host.scrollView.isScrollEnabled, "Provisional rows remain scrollable")
            #expect(host.onOpenPhoto == nil)
            #expect(host.onToggleSelection == nil)
            #expect(host.onSelectionChanged == nil)
            #expect(host.dragOutProvider == nil)
            #expect(host.contextMenuActions == nil)
            #expect(host.onContextMenuAction == nil)
            #expect(model.items.isEmpty)
            #expect(model.isolatedInventoryAuthorityForTesting == .hydrating)
            await repository.release()
            try await loading.value
            try await waitUntil { host.onOpenPhoto != nil && model.items.count == 10 }
            #expect(host.scrollView.isScrollEnabled)
            #expect(host.onOpenPhoto != nil)
            #expect(host.onToggleSelection != nil)
            #expect(host.onSelectionChanged != nil)
            #expect(host.dragOutProvider != nil)
            #expect(host.contextMenuActions != nil)
            #expect(host.onContextMenuAction != nil)
            #expect(model.isolatedInventoryAuthorityForTesting == .authoritative)
        } catch {
            loading.cancel()
            await repository.release()
            _ = await loading.result
            await runtime.shutdown()
            await fixture.feed.stopPrefetch()
            throw error
        }
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aDrawnKnownPlaceholderRevealsTheProductionScreenWithoutThumbnailBytes(listingCompleted: Bool) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ThumbnailCache(rootDirectory: directory)
        let feed = UIKitThumbnailFeed(cache: cache, loader: ChromeProbeLoader())
        let items = Array(fixture.items.prefix(10))
        let repository = MobileHeldProvisionalRepository(items: items)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [], thumbnailFeed: feed, thumbnailCache: cache)
        model.setApplicationActive(false)
        let runtime = await installRuntime(into: model, fixture: fixture, feed: feed)
        let loading = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: repository) }
        do {
            if listingCompleted {
                try #require(await repository.waitForPage())
                await repository.release()
                try await loading.value
            }
            let screen = try mountScreen(model: model)
            defer { screen.close() }
            try #require(await repository.waitForPage())
            try await waitUntil {
                descendants(screen.window).contains { ($0 as? UIKitTimelineGridHostView)?.itemUIDs.count == 10 }
            }
            let host = try #require(descendants(screen.window).compactMap { $0 as? UIKitTimelineGridHostView }.first)
            try #require(host.isMetal3Capable, "SETUP: the production Metal renderer is available")
            try #require(host.accessibilityFramePlan()?.visibleSlots.isEmpty == false)
            try await waitUntil { host.drawnFrameCount > 0 }
            let deadline = ContinuousClock.now + .seconds(2)
            while !model.loadState.isContentReady, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(items.allSatisfy { feed.memoryImage(for: $0.uid) == nil }, "No thumbnail has arrived")
            let expectedState: LibraryLoadState =
                listingCompleted
                ? .contentReady(count: 10) : .provisionalContent(count: 10, frameReady: true)
            #expect(model.loadState == expectedState)
            #expect(model.loadState.isContentReady, "A drawn placeholder lifts the initial loading cover")
            #expect(model.loadState.hasSettled == listingCompleted)
            #expect(model.items.count == (listingCompleted ? 10 : 0))
            #expect(model.isolatedInventoryAuthorityForTesting == (listingCompleted ? .authoritative : .hydrating))
            #expect((host.onOpenPhoto != nil) == listingCompleted)
            #expect((host.onToggleSelection != nil) == listingCompleted)
            if !listingCompleted {
                await repository.release()
                try await loading.value
            }
            #expect(model.loadState == .contentReady(count: 10), "Qualification keeps the already visible grid")
            #expect(model.loadState.hasSettled)
            #expect(model.isolatedInventoryAuthorityForTesting == .authoritative)
            #expect(items.allSatisfy { feed.memoryImage(for: $0.uid) == nil })
        } catch {
            loading.cancel()
            await repository.release()
            _ = await loading.result
            await runtime.shutdown()
            await feed.stopPrefetch()
            throw error
        }
        await runtime.shutdown()
        await feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func productionScreenKeepsTheVisiblePhotoAnchoredAsOlderMetadataPagesArrive() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 36)
        defer { fixture.removeCache() }
        let initial = Array(fixture.items.suffix(60))
        let repository = MobileHeldProvisionalRepository(items: initial)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [], thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.setApplicationActive(false)
        let runtime = await installRuntime(into: model, fixture: fixture)
        let screen = try mountScreen(model: model)
        defer { screen.close() }
        let loading = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: repository) }
        do {
            try #require(await repository.waitForPage())
            try await waitUntil {
                descendants(screen.window).contains { ($0 as? UIKitTimelineGridHostView)?.itemUIDs.count == 60 }
            }
            let host = try #require(descendants(screen.window).compactMap { $0 as? UIKitTimelineGridHostView }.first)
            host.restoreScrollAnchor(GridScrollAnchor(itemID: initial[24].uid, topOffset: host.safeAreaInsets.top + 11))
            let anchor = try #require(host.currentScrollAnchor())
            let distanceFromBar = anchor.topOffset - host.safeAreaInsets.top
            try #require(
                host.scrollView.contentOffset.y > -host.safeAreaInsets.top, "SETUP: an interior scroll position")
            for count in [120, fixture.items.count] {
                let known = Array(fixture.items.suffix(count))
                await repository.publish(items: known)
                try await waitUntil { host.itemUIDs.count == count }
                let after = try #require(host.currentScrollAnchor())
                #expect(after.itemID == anchor.itemID, "Growing metadata keeps the same photo below the top bar")
                #expect(
                    abs(after.topOffset - host.safeAreaInsets.top - distanceFromBar) < 0.5,
                    "Growing metadata keeps its viewport offset")
                #expect(Set(host.itemUIDs) == Set(known.map(\.uid)), "Only known photos occupy placeholder slots")
                #expect(model.items.isEmpty)
                #expect(model.sections.isEmpty, "Provisional pages do not enter search or suggestion inventories")
                #expect(model.isolatedInventoryAuthorityForTesting == .hydrating)
                #expect(host.onOpenPhoto == nil)
                #expect(host.onToggleSelection == nil)
            }
            await repository.release()
            try await loading.value
            try await waitUntil { host.onOpenPhoto != nil }
            let completed = try #require(host.currentScrollAnchor())
            #expect(completed.itemID == anchor.itemID)
            #expect(abs(completed.topOffset - host.safeAreaInsets.top - distanceFromBar) < 0.5)
            #expect(Set(model.items.map(\.uid)) == Set(fixture.items.map(\.uid)))
            #expect(model.isolatedInventoryAuthorityForTesting == .authoritative)
        } catch {
            loading.cancel()
            await repository.release()
            _ = await loading.result
            await runtime.shutdown()
            await fixture.feed.stopPrefetch()
            throw error
        }
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationAndAccountReplacementRetireVisibleProvisionalRows(replacingAccount: Bool) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let items = Array(fixture.items.prefix(10))
        let repository = MobileHeldProvisionalRepository(items: items)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [], thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.setApplicationActive(false)
        let runtime = await installRuntime(into: model, fixture: fixture)
        let screen = try mountScreen(model: model)
        defer { screen.close() }
        let loading = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: repository) }
        do {
            try #require(await repository.waitForPage())
            try await waitUntil { model.loadState.isContentReady }
            #expect(model.isProvisionalPresentation)
            #expect(!model.loadState.hasSettled)
            #expect(model.gridItems.count == 10)
            #expect(model.items.isEmpty)
            if replacingAccount {
                model.configure(session: nil, store: SessionKeychainStore())
                #expect(!model.isProvisionalPresentation, "The shipping account reset removes the old projection")
                await runtime.shutdown()
                let replacement = PhotoItem(
                    uid: PhotoUID(volumeID: "replacement", nodeID: "photo"), captureTime: .distantPast,
                    mediaType: "image/jpeg")
                let sections = [TimelineSection(id: "replacement", date: .distantPast, title: "", items: [replacement])]
                model.installIsolatedLibrary(
                    session: ProtonSession(
                        uid: "replacement-provisional-test", accessToken: "fixture", refreshToken: "fixture",
                        keyPassword: "fixture"),
                    store: SessionKeychainStore(), backend: fixture.backend, sections: sections,
                    thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
                let replacementState = model.loadState
                await repository.publish(items: items)
                #expect(model.gridItems == [replacement], "A late provisional callback cannot enter another account")
                await repository.release()
                try await loading.value
                #expect(model.items == [replacement], "A late old page cannot overwrite the replacement account")
                #expect(model.gridItems == [replacement])
                #expect(model.loadState == replacementState, "Old cleanup cannot reset the replacement presentation")
                #expect(model.isolatedInventoryAuthorityForTesting == .authoritative)
                model.configure(session: nil, store: SessionKeychainStore())
            } else {
                loading.cancel()
                await repository.release()
                await #expect(throws: CancellationError.self) { try await loading.value }
                #expect(model.gridItems.isEmpty)
                #expect(model.items.isEmpty)
                #expect(model.sections.isEmpty)
                #expect(model.loadState == .preparingInventory)
                #expect(!model.isCompletelyEmpty, "Cancellation cannot certify authoritative zero")
                #expect(model.isolatedInventoryAuthorityForTesting == .hydrating)
            }
            #expect(!model.isProvisionalPresentation)
        } catch {
            loading.cancel()
            await repository.release()
            _ = await loading.result
            await runtime.shutdown()
            await fixture.feed.stopPrefetch()
            throw error
        }
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func aLaterPageFailureRemovesTheGridAndANewInitialReadStartsCleanly() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let failedItems = Array(fixture.items.prefix(10))
        let retryItems = Array(fixture.items.suffix(10))
        let first = MobileHeldProvisionalRepository(items: failedItems)
        let second = MobileHeldProvisionalRepository(items: retryItems)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [], thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.setApplicationActive(false)
        let runtime = await installRuntime(into: model, fixture: fixture)
        let screen = try mountScreen(model: model)
        defer { screen.close() }
        let loading = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: first) }
        var retry: Task<Void, any Error>?
        do {
            try #require(await first.waitForPage())
            try await waitUntil { model.loadState.isContentReady }
            #expect(Set(model.gridItems.map(\.uid)) == Set(failedItems.map(\.uid)))
            await first.release(failing: true)
            await #expect(throws: URLError.self) { try await loading.value }
            #expect(model.gridItems.isEmpty)
            #expect(model.items.isEmpty)
            #expect(model.sections.isEmpty)
            #expect(!model.isProvisionalPresentation)
            #expect(model.loadState.failure?.retryable == true)
            #expect(
                model.loadState.failure?.message
                    == LibraryLoadFailureMessage.message(for: URLError(.networkConnectionLost)))
            #expect(!model.isCompletelyEmpty)
            #expect(model.isolatedInventoryAuthorityForTesting == .hydrating)
            try await waitUntil { !descendants(screen.window).contains { $0 is UIKitTimelineGridHostView } }
            let next = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: second) }
            retry = next
            try #require(await second.waitForPage())
            try await waitUntil { model.loadState.isContentReady }
            #expect(model.loadState.failure == nil)
            #expect(Set(model.gridItems.map(\.uid)) == Set(retryItems.map(\.uid)))
            #expect(Set(model.gridItems.map(\.uid)).isDisjoint(with: Set(failedItems.map(\.uid))))
            #expect(model.items.isEmpty)
            #expect(model.sections.isEmpty)
            #expect(model.isolatedInventoryAuthorityForTesting == .hydrating)
            await second.release()
            try await next.value
            #expect(Set(model.items.map(\.uid)) == Set(retryItems.map(\.uid)))
            #expect(model.isolatedInventoryAuthorityForTesting == .authoritative)
        } catch {
            loading.cancel()
            retry?.cancel()
            await first.release()
            await second.release()
            _ = await loading.result
            _ = await retry?.result
            await runtime.shutdown()
            await fixture.feed.stopPrefetch()
            throw error
        }
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }

    private func mountScreen(model: MobileLibraryModel) throws -> (window: UIWindow, close: @MainActor () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let context = MobileSceneContext()
        context.attach(window: window)
        window.rootViewController = UIHostingController(
            rootView: MobileTimelineScreen(surface: .library)
                .environment(model)
                .environment(MobileViewerRouter())
                .environment(context))
        window.makeKeyAndVisible()
        return (
            window,
            {
                descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
                window.isHidden = true
                window.rootViewController = nil
                previousKey?.makeKey()
            }
        )
    }

    private func installRuntime(
        into model: MobileLibraryModel, fixture: MobileSignedInFixture, feed: UIKitThumbnailFeed? = nil
    ) async -> LibrarySourceAnalysisRuntime {
        let source = MobileProvisionalSources()
        let coordinator = LibrarySourceCoordinator(
            remote: source, thumbnailLoader: fixture.backend, inventoryStore: nil)
        await coordinator.prepare()
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: coordinator, feed: (feed ?? fixture.feed).feedCore,
            assets: MLAssetUniverse(), initiallyActive: false, onAssetsChanged: {})
        model.installIsolatedSourceAnalysisForTests(runtime)
        return runtime
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

private actor MobileHeldProvisionalRepository: PhotosRepository {
    private var sections: [TimelineSection]
    private var observer: (@Sendable (ProvisionalTimelineSnapshot) async -> Void)?
    private var delivered = false
    private var released = false
    private var failing = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(items: [PhotoItem]) {
        sections = [TimelineSection(id: "known", date: .distantPast, title: "", items: items)]
    }

    func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }

    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        try await loadTimelineSnapshot(onProvisional: { _ in })
    }

    func loadTimelineSnapshot(
        onProvisional: @escaping @Sendable (ProvisionalTimelineSnapshot) async -> Void
    ) async throws -> TimelineLoadSnapshot {
        observer = onProvisional
        defer { observer = nil }
        await onProvisional(ProvisionalTimelineSnapshot(sections: sections))
        delivered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        if failing { throw URLError(.networkConnectionLost) }
        return TimelineLoadSnapshot(sections: sections, validationToken: "qualified")
    }

    func waitForPage() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !delivered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return delivered
    }

    func publish(items: [PhotoItem]) async {
        sections = [TimelineSection(id: "known", date: .distantPast, title: "", items: items)]
        await observer?(ProvisionalTimelineSnapshot(sections: sections))
    }

    func release(failing: Bool = false) {
        self.failing = failing
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct MobileProvisionalSources: LibrarySourceRemoteBackend {
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] { [] }
    func librarySourceItems(for _: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] { [] }
}
