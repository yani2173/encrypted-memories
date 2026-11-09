import Foundation
import MediaByteCache
import MediaFeedCore
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct ProvisionalTimelinePresentationTests {
    @Test func placeholderReadinessAcceptsKnownFreshMetadataAndKeepsTheCachedPathUnchanged() {
        #expect(LibraryLoadState.provisionalContent(count: 10, frameReady: false).allowsPlaceholderContentReady)
        #expect(LibraryLoadState.loadingContent(count: 10, usingCachedInventory: false).allowsPlaceholderContentReady)
        #expect(!LibraryLoadState.loadingContent(count: 10, usingCachedInventory: true).allowsPlaceholderContentReady)
        #expect(!LibraryLoadState.validatingCachedContent(count: 10).allowsPlaceholderContentReady)
        #expect(!LibraryLoadState.preparingInventory.allowsPlaceholderContentReady)
        #expect(!LibraryLoadState.empty.allowsPlaceholderContentReady)
        #expect(!LibraryLoadState.failed(message: "offline", retryable: true).allowsPlaceholderContentReady)
    }

    #if DEBUG
        @MainActor @Test func thumbnailAccessStartsBeforePresentationAndEndsAfterCompletion() async throws {
            let loader = RecordingProvisionalThumbnails()
            try await withHeldPresentation(loader: loader) { model, repository in
                #expect(await loader.events == ["begin", "update"])
                #expect(await loader.knownUIDs == Set(model.gridItems.map(\.uid)))
                #expect(model.gridItems.count == 10)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                await repository.release()
            } after: { model in
                #expect(model.wholeLibraryInventoryAuthority == .authoritative)
                #expect(model.allItems.count == 10)
            }
            #expect(await loader.events == ["begin", "update", "end"])
        }
    #endif

    #if DEBUG
        @MainActor @Test(arguments: [false, true])
        func failureAndCancellationRetireTheirThumbnailAccess(cancel: Bool) async throws {
            let loader = RecordingProvisionalThumbnails()
            try await withHeldPresentation(loader: loader) { model, repository in
                #expect(await loader.events == ["begin", "update"])
                model.markInitialContentReady()
                if cancel { model.cancelInitialLoadForTesting() }
                await repository.release(failing: !cancel)
            } after: { model in
                #expect(model.gridItems.isEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(model.initialLibraryChangeToken == "")
            }
            #expect(await loader.events == ["begin", "update", "end"])
            #expect(await loader.knownUIDs.isEmpty)
        }
    #endif

    #if DEBUG
        @MainActor @Test func aLaterPageFailureRemovesProvisionalRowsAndUsesTheExistingErrorState() async throws {
            try await withHeldPresentation { model, repository in
                model.markInitialContentReady()
                #expect(model.gridItems.count == 10)
                await repository.release(failing: true)
            } after: { model in
                #expect(model.gridItems.isEmpty)
                #expect(model.gridSections.isEmpty)
                #expect(model.allItems.isEmpty)
                #expect(model.wholeLibraryUIDs.isEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(model.initialLibraryChangeToken == "")
                #expect(model.initialLibraryLoadState.failure?.retryable == true)
                #expect(!model.initialLibraryLoadState.isCompletelyEmpty)
                if case .failed(_, retryable: true) = model.gridState {
                } else {
                    Issue.record("The existing error cover must replace the provisional projection")
                }
            }
        }
    #endif

    #if DEBUG
        @MainActor @Test func cancellationRemovesProvisionalRowsWithoutCertifyingEmpty() async throws {
            try await withHeldPresentation { model, repository in
                model.markInitialContentReady()
                #expect(model.gridItems.count == 10)
                model.cancelInitialLoadForTesting()
                await repository.release()
            } after: { model in
                #expect(model.gridItems.isEmpty)
                #expect(model.gridSections.isEmpty)
                #expect(model.allItems.isEmpty)
                #expect(model.wholeLibraryUIDs.isEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(model.initialLibraryChangeToken == "")
                #expect(model.initialLibraryLoadState == .preparingInventory)
                #expect(!model.initialLibraryLoadState.isCompletelyEmpty)
            }
        }
    #endif

    #if DEBUG
        @MainActor @Test func anEmptyPageDoesNotCertifyEmptyUntilCompletion() async throws {
            try await withHeldPresentation(count: 0) { model, repository in
                #expect(model.gridItems.isEmpty)
                #expect(model.initialLibraryLoadState.knownCount == nil)
                model.markInitialContentReady()
                #expect(!model.initialLibraryLoadState.isContentReady)
                #expect(!model.initialLibraryLoadState.isCompletelyEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(model.initialLibraryChangeToken == nil)
                await repository.release()
            } after: { model in
                #expect(model.initialLibraryLoadState.isCompletelyEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .authoritative)
                #expect(model.initialLibraryChangeToken == "completed")
            }
        }
    #endif

    #if DEBUG
        @MainActor private func withHeldPresentation(
            count: Int = 10,
            loader: any ThumbnailBatchLoader = NoProvisionalThumbnails(),
            during: @MainActor (TimelineViewModel, HeldProvisionalRepository) async throws -> Void,
            after: @MainActor (TimelineViewModel) -> Void
        ) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = HeldProvisionalRepository(count: count)
            let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: loader)
            let model = TimelineViewModel(repository: repository, feed: feed)
            let loading = Task { await model.load() }
            do {
                try #require(await repository.waitUntilPageWasDelivered())
                try await during(model, repository)
                await loading.value
                after(model)
            } catch {
                model.cancelInitialLoadForTesting()
                await repository.release()
                await loading.value
                await feed.stopPrefetch()
                throw error
            }
            await feed.stopPrefetch()
        }
    #endif

    #if DEBUG
        @MainActor @Test func knownRowsAppearOnlyInPresentationUntilTheCompleteLoadQualifies() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = HeldProvisionalRepository()
            let feed = ThumbnailFeedCore(
                cache: ThumbnailCache(rootDirectory: directory), loader: NoProvisionalThumbnails())
            let model = TimelineViewModel(repository: repository, feed: feed)
            let loading = Task { await model.load() }
            do {
                try #require(
                    await repository.waitUntilPageWasDelivered(), "SETUP: the page producer must enter its hold")
                let expected = Set((0..<10).map { PhotoUID(volumeID: "volume", nodeID: "photo-\($0)") })
                #expect(Set(model.gridItems.map(\.uid)) == expected, "Only the grid receives provisional known rows")
                #expect(model.gridItems.count == 10, "Never invent an estimated total")
                #expect(model.initialLibraryLoadState.knownCount == 10)
                #expect(model.allItems.isEmpty, "An unfinished page is not the business inventory")
                #expect(model.wholeLibraryUIDs.isEmpty)
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(model.initialLibraryChangeToken == nil)
                #expect(!model.initialLibraryLoadState.isCompletelyEmpty)
                model.markInitialContentReady()
                #expect(
                    model.initialLibraryLoadState.isContentReady, "An encoded known-photo placeholder frame can show")
                #expect(!model.initialLibraryLoadState.hasSettled, "Showing placeholders does not finish the listing")
                #expect(model.wholeLibraryInventoryAuthority == .hydrating)
                #expect(model.initialLibraryChangeToken == nil)
                await repository.release()
                await loading.value
                #expect(Set(model.allItems.map(\.uid)) == expected)
                #expect(Set(model.wholeLibraryUIDs) == expected)
                #expect(model.wholeLibraryInventoryAuthority == .authoritative)
                #expect(model.initialLibraryChangeToken == "completed")
                #expect(model.gridItems.count == 10)
                model.markInitialContentReady()
                #expect(model.initialLibraryLoadState.hasSettled)
            } catch {
                model.cancelInitialLoadForTesting()
                await repository.release()
                await loading.value
                await feed.stopPrefetch()
                throw error
            }
            await feed.stopPrefetch()
        }
    #endif
}

private actor HeldProvisionalRepository: PhotosRepository {
    private enum Fault: Error { case laterPage }
    private let sections: [TimelineSection]
    private var pageWasDelivered = false
    private var released = false
    private var failing = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(count: Int = 10) {
        let items = (0..<count).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: "photo-\($0)"),
                captureTime: Date(timeIntervalSince1970: Double($0 + 1)), mediaType: "image/jpeg")
        }
        sections = [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
    }

    func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }
    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        try await loadTimelineSnapshot(onProvisional: { _ in })
    }

    func loadTimelineSnapshot(
        onProvisional: @escaping @Sendable (ProvisionalTimelineSnapshot) async -> Void
    ) async throws -> TimelineLoadSnapshot {
        await onProvisional(ProvisionalTimelineSnapshot(sections: sections))
        pageWasDelivered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        if failing { throw Fault.laterPage }
        return TimelineLoadSnapshot(sections: sections, validationToken: "completed")
    }

    func waitUntilPageWasDelivered() async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !pageWasDelivered, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return pageWasDelivered
    }

    func release(failing: Bool = false) {
        self.failing = failing
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct NoProvisionalThumbnails: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        ThumbnailBatchLoadResult()
    }
}

private actor RecordingProvisionalThumbnails: ThumbnailBatchLoader, ProvisionalThumbnailAuthorizing {
    private(set) var events: [String] = []
    private(set) var knownUIDs: Set<PhotoUID> = []

    func beginProvisionalThumbnailAccess() -> UUID? {
        events.append("begin")
        return UUID()
    }

    func updateProvisionalThumbnailAccess(_ uids: [PhotoUID], using lease: UUID) {
        events.append("update")
        knownUIDs = Set(uids)
    }

    func endProvisionalThumbnailAccess(_ lease: UUID) {
        events.append("end")
        knownUIDs = []
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        ThumbnailBatchLoadResult()
    }
}
