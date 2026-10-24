import PhotosCore
import Testing

@testable import TimelineCore

/// Covers the five library-load phases the product requires: unknown count, known count / no thumbnails,
/// first content ready, empty library, and error - plus the transitions and edge cases between them.
@Suite struct LibraryLoadStateTests {
    @Test func rejectedByteRouteSettlesBeforeFirstFrameButPreservesPresentedContent() {
        for cached in [false, true] {
            let failed = LibraryLoadPolicy.reduce(
                .loadingContent(count: 37_249, usingCachedInventory: cached),
                .contentLoadFailed(message: "test-error")
            )
            #expect(failed == .failed(message: "test-error", retryable: true))
            #expect(!failed.isLoading)
        }
        let presented = LibraryLoadState.contentReady(count: 37_249)
        #expect(LibraryLoadPolicy.reduce(presented, .contentLoadFailed(message: "test-error")) == presented)
    }

    @Test func completelyEmptyRequiresAuthoritativeZeroKnownItems() {
        for count in [nil, -1, 0, 1, 10_000] as [Int?] {
            for authority in [SourceInventoryAuthority.hydrating, .cached, .authoritative] {
                #expect(
                    LibraryEmptyPolicy.isCompletelyEmpty(knownItemCount: count, authority: authority)
                        == (count == 0 && authority == .authoritative)
                )
            }
        }
    }

    @Test func firstSignInWithLaterMetadataNeverSettlesEmpty() {
        let waiting = reduce(.initial, [.firstContentReady])
        #expect(waiting.isLoading)
        #expect(!waiting.isCompletelyEmpty)
        let known = reduce(waiting, [.authoritativeInventoryResolved(count: 10, requiresNewFrame: true)])
        #expect(known.knownCount == 10)
        #expect(known.isLoading)
        #expect(!known.isCompletelyEmpty)
        #expect(reduce(known, [.firstContentReady]) == .contentReady(count: 10))
    }

    @Test func invalidNegativeCountCannotProveAnEmptyLibrary() {
        #expect(reduce(.initial, [.inventoryResolved(count: -1, cached: false)]).isLoading)
        #expect(reduce(.initial, [.authoritativeInventoryResolved(count: -1, requiresNewFrame: false)]).isLoading)
    }

    private func reduce(_ state: LibraryLoadState, _ events: [LibraryLoadEvent]) -> LibraryLoadState {
        events.reduce(state) { LibraryLoadPolicy.reduce($0, $1) }
    }

    @Test func initialStateIsPreparingWithUnknownCount() {
        let state = LibraryLoadState.initial
        #expect(state == .preparingInventory)
        #expect(state.knownCount == nil)  // count is genuinely unknown; must not fake a number
        #expect(state.isLoading)  // shell shows an indeterminate spinner
        #expect(!state.isContentReady)
        #expect(!state.hasSettled)
    }

    @Test func freshInventoryResolvingMovesToLoadingContentWithCount() {
        let state = reduce(.initial, [.inventoryResolved(count: 20_000, cached: false)])
        #expect(state == .loadingContent(count: 20_000, usingCachedInventory: false))
        #expect(state.knownCount == 20_000)  // count shown calmly once known
        #expect(state.isLoading)  // still loading; grid must not show yet (no blank grid)
        #expect(!state.isContentReady)
        #expect(!state.hasSettled)
    }

    @Test func cachedInventoryIsDistinguishedFromFresh() {
        let cached = reduce(.initial, [.inventoryResolved(count: 42, cached: true)])
        #expect(cached == .loadingContent(count: 42, usingCachedInventory: true))
        // A fresh load afterwards flips the cached flag and can revise the count without layout jumps.
        let fresh = reduce(cached, [.inventoryResolved(count: 50, cached: false)])
        #expect(fresh == .loadingContent(count: 50, usingCachedInventory: false))
        #expect(fresh.knownCount == 50)
    }

    @Test func firstContentReadyPromotesLoadingToContentReady() {
        let state = reduce(
            .initial,
            [
                .inventoryResolved(count: 12, cached: false),
                .firstContentReady,
            ])
        #expect(state == .contentReady(count: 12))
        #expect(state.isContentReady)
        #expect(!state.isLoading)  // spinner gone; grid is presentable
        #expect(state.hasSettled)
        #expect(state.knownCount == 12)
    }

    @Test func cachedFirstFrameIsPresentableBeforeAuthoritativeValidation() {
        let cachedFrame = reduce(
            .initial,
            [
                .inventoryResolved(count: 12, cached: true),
                .firstContentReady,
            ])
        #expect(cachedFrame == .contentReady(count: 12))
        #expect(!cachedFrame.isLoading)

        let confirmed = LibraryLoadPolicy.reduce(
            cachedFrame,
            .authoritativeInventoryResolved(count: 12, requiresNewFrame: false)
        )
        #expect(confirmed == .contentReady(count: 12))
    }

    @Test func changedAuthoritativeInventoryDoesNotCoverAnAlreadyPresentedCachedFrame() {
        let cachedFrame = reduce(
            .initial,
            [
                .inventoryResolved(count: 12, cached: true),
                .firstContentReady,
            ])
        let refreshed = LibraryLoadPolicy.reduce(
            cachedFrame,
            .authoritativeInventoryResolved(count: 13, requiresNewFrame: true)
        )
        #expect(refreshed == .contentReady(count: 13))
    }

    @Test func countKeepsUpdatingAfterContentIsReady() {
        // A later refresh (e.g. an upload landed) must update the count without leaving the presented grid.
        let state = reduce(
            .initial,
            [
                .inventoryResolved(count: 12, cached: false),
                .firstContentReady,
                .inventoryResolved(count: 13, cached: false),
            ])
        #expect(state == .contentReady(count: 13))
        #expect(state.isContentReady)
    }

    @Test func firstContentReadyBeforeInventoryIsIgnored() {
        // A stray first-content signal with no known inventory must never reveal an unprepared grid.
        let state = reduce(.initial, [.firstContentReady])
        #expect(state == .preparingInventory)
        #expect(!state.isContentReady)
    }

    @Test func zeroCountResolvesToEmpty() {
        let state = reduce(.initial, [.inventoryResolved(count: 0, cached: false)])
        #expect(state == .empty)
        #expect(state.isEmpty)
        #expect(state.knownCount == 0)
        #expect(!state.isLoading)  // Empty state settles without a perpetual spinner.
        #expect(state.hasSettled)
    }

    @Test func emptyIsReachedFromCachedZeroToo() {
        let cached = reduce(.initial, [.inventoryResolved(count: 0, cached: true)])
        #expect(cached == .validatingCachedContent(count: 0))
        #expect(
            reduce(cached, [.authoritativeInventoryResolved(count: 0, requiresNewFrame: false)]) == .empty
        )
    }

    @Test func failedValidationOfCachedEmptyInventoryShowsFailure() {
        let cached = reduce(.initial, [.inventoryResolved(count: 0, cached: true)])
        #expect(
            reduce(cached, [.failed(message: "offline", retryable: true)])
                == .failed(message: "offline", retryable: true)
        )
    }

    @Test func cachedEmptyWaitsForAuthoritativeNonemptyFrame() {
        let cached = reduce(.initial, [.inventoryResolved(count: 0, cached: true)])
        let remote = reduce(
            cached,
            [
                .authoritativeInventoryResolved(count: 3, requiresNewFrame: true)
            ])
        #expect(remote == .loadingContent(count: 3, usingCachedInventory: false))
        #expect(LibraryLoadPolicy.reduce(remote, .firstContentReady) == .contentReady(count: 3))
    }

    @Test func libraryEmptiedAfterContentBecomesEmpty() {
        // When the inventory becomes empty after content is ready, the grid collapses to the empty state.
        let state = reduce(
            .initial,
            [
                .inventoryResolved(count: 3, cached: false),
                .firstContentReady,
                .inventoryResolved(count: 0, cached: false),
            ])
        #expect(state == .empty)
    }

    @Test func failureBeforeContentSurfacesError() {
        let state = reduce(.initial, [.failed(message: "Network unavailable", retryable: true)])
        #expect(state == .failed(message: "Network unavailable", retryable: true))
        #expect(state.failure?.message == "Network unavailable")
        #expect(state.failure?.retryable == true)
        #expect(!state.isLoading)  // Errors settle with a retry action instead of a spinner.
        #expect(state.hasSettled)
    }

    @Test func failureAfterCachedInventoryKeepsShowingCachedContent() {
        // A cached snapshot is loading; the fresh refresh then fails. The user keeps their (cached) photos and
        // browses offline - no error wall replaces resolvable content.
        let state = reduce(
            .initial,
            [
                .inventoryResolved(count: 100, cached: true),
                .failed(message: "Timed out", retryable: true),
            ])
        #expect(state == .loadingContent(count: 100, usingCachedInventory: false))
        #expect(LibraryLoadPolicy.reduce(state, .firstContentReady) == .contentReady(count: 100))
    }

    @Test func authoritativeFailurePresentsAnAlreadyRenderedCachedFrame() {
        let state = reduce(
            .initial,
            [
                .inventoryResolved(count: 100, cached: true),
                .firstContentReady,
                .failed(message: "Timed out", retryable: true),
            ])
        #expect(state == .contentReady(count: 100))
    }

    @Test func failureAfterEmptyDoesNotSurface() {
        // Settled-empty then a background refresh fails to stays empty, not an error.
        let state = reduce(
            .initial,
            [
                .inventoryResolved(count: 0, cached: false),
                .failed(message: "Timed out", retryable: true),
            ])
        #expect(state == .empty)
    }

    @Test func nonRetryableFailureIsPreserved() {
        let state = reduce(.initial, [.failed(message: "Session expired", retryable: false)])
        #expect(state.failure?.retryable == false)
    }

    @Test func backgroundFailureDoesNotYankPresentedGrid() {
        // Once content is on screen, a subsequent (background refresh) failure keeps the grid intact.
        let state = reduce(
            .initial,
            [
                .inventoryResolved(count: 7, cached: false),
                .firstContentReady,
                .failed(message: "Refresh failed", retryable: true),
            ])
        #expect(state == .contentReady(count: 7))
        #expect(state.isContentReady)
    }

    @Test func resetReturnsToPreparingFromAnyState() {
        let states: [LibraryLoadState] = [
            .preparingInventory,
            .loadingContent(count: 5, usingCachedInventory: true),
            .validatingCachedContent(count: 5),
            .contentReady(count: 5),
            .empty,
            .failed(message: "x", retryable: true),
        ]
        for start in states {
            #expect(LibraryLoadPolicy.reduce(start, .reset) == .preparingInventory)
        }
    }

    @Test func retryAfterFailureReloads() {
        // Failure to reset (retry tapped) to fresh inventory to content ready.
        let state = reduce(
            .initial,
            [
                .failed(message: "Network unavailable", retryable: true),
                .reset,
                .inventoryResolved(count: 9, cached: false),
                .firstContentReady,
            ])
        #expect(state == .contentReady(count: 9))
    }

    @Test func automaticAuthoritativeRefreshRecoversWithoutReset() {
        let failed = LibraryLoadState.failed(message: "Network unavailable", retryable: true)
        let loading = LibraryLoadPolicy.reduce(
            failed, .authoritativeInventoryResolved(count: 9, requiresNewFrame: true)
        )
        #expect(loading == .loadingContent(count: 9, usingCachedInventory: false))
        #expect(LibraryLoadPolicy.reduce(loading, .firstContentReady) == .contentReady(count: 9))
        #expect(
            LibraryLoadPolicy.reduce(failed, .authoritativeInventoryResolved(count: 0, requiresNewFrame: false))
                == .empty)
    }

    @Test func stateIsValueSemantic() {
        // Equatable + Sendable value type - safe to publish across the app without shared mutable state.
        let a = LibraryLoadState.loadingContent(count: 1, usingCachedInventory: false)
        let b = LibraryLoadState.loadingContent(count: 1, usingCachedInventory: false)
        #expect(a == b)
        #expect(a != .loadingContent(count: 1, usingCachedInventory: true))
    }
}
