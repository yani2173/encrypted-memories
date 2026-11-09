import CoreGraphics
import MediaByteCache
import MediaCache
import PhotosCore
import SwiftUI
import Testing

@testable import TimelineCore
@testable import TimelineFeature

/// Retry is shown only when the recorded failure is retryable and the device is online.
/// The iOS error screen honors the same flag and offline exception.
/// Every failure reaches the view through a production route: a throwing repository drives `load()`
/// for the retryable case, and the non-retryable case is replayed through the first-load reducer
/// seam that production uses for the same mirroring.
/// The direction of the comparison matters: with `retryable: true` the actions row joins the
/// centered stack, so the stack grows and its first ink row moves up; with `retryable: false` it does
/// not. The comparison is strict and has no pixel or row threshold, so it holds for any font or
/// renderer metrics, and an inverted switch fails it. Each side is compared as its settled render:
/// the first two consecutive renders that agree.
@MainActor
@Suite struct TimelineViewRetryVisibilityTests {
    #if DEBUG
        @Test func onlineRetryButtonFollowsTheFailureFlagByDirection() async throws {
            // The real first-load failure route: the repository throws and `load()` mirrors the failure.
            let shownFeed = makeFeed()
            let shownModel = TimelineViewModel(repository: FailingStartupRepository(), feed: shownFeed.feedCore)
            await shownModel.load()
            guard case .failed(let message, let retryable) = shownModel.state else {
                Issue.record("A thrown first load must surface the failure state")
                return
            }
            #expect(retryable, "The production route must record a thrown first read as retryable")
            // A render of the same state must settle: two consecutive renders are identical (see
            // `RenderedInk.stablePixels`). A view that never settles fails the test.
            let shown = try RenderedInk.stablePixels(label: "failure route") {
                try renderedPixels(of: shownModel, feed: shownFeed)
            }

            // Only the Retry affordance may change the render. Its layout height makes the centered stack
            // taller, so the first ink row (the title symbol) sits higher; whether the renderer also draws
            // the glass button itself does not matter. Strict inequalities hold for any metrics, and an
            // inverted switch flips both of them.
            let bare = try RenderedInk.stablePixels(label: "failure without Retry") {
                try renderReplayedFailure(message: message, retryable: false)
            }
            let withButton = try RenderedInk.stablePixels(label: "failure with Retry") {
                try renderReplayedFailure(message: message, retryable: true)
            }
            #expect(
                Self.differingPixels(withButton, bare) > 0,
                "The retryable flag must change the render")
            #expect(
                Self.firstInkRow(withButton) < Self.firstInkRow(bare),
                "The retryable flag must add the Retry button's layout height (first ink rows: \(Self.firstInkRow(withButton)) vs \(Self.firstInkRow(bare)))"
            )
            #expect(
                Self.firstInkRow(shown) < Self.firstInkRow(bare),
                "The real failure route must draw the Retry button (first ink rows: \(Self.firstInkRow(shown)) vs \(Self.firstInkRow(bare)))"
            )
        }
    #endif

    #if DEBUG
        @Test func theErrorMessageDrawsOnTheErrorScreen() throws {
            // A different description text must change the drawn pixels; this proves the failure text
            // renders on macOS and the screen is not just the static background.
            let first = try renderReplayedFailure(message: "First fixture failure", retryable: true)
            let second = try renderReplayedFailure(message: "Second fixture failure", retryable: true)
            #expect(
                Self.differingPixels(first, second) > 300,
                "The failure message must draw ink")
        }
    #endif

    #if DEBUG
        @Test func provisionalEmptyGridPreservesFailureRetryability() {
            for retryable in [false, true] {
                let feed = makeFeed()
                let model = TimelineViewModel(repository: NoopRepository(), feed: feed.feedCore)
                model.applyIsolatedInitialLoadEventsForTesting([.failed(message: "Failure", retryable: retryable)])
                model.state = .empty
                guard case .failed(let message, let actualRetryable) = model.gridState else {
                    Issue.record("A provisional empty grid must surface the first-load failure")
                    continue
                }
                #expect(message == "Failure")
                #expect(actualRetryable == retryable)
            }
        }
    #endif

    // MARK: - Helpers

    private func makeFeed() -> ThumbnailFeed {
        ThumbnailFeed(
            cache: ThumbnailCache(
                namespace: "tests-retry-visibility-\(UUID().uuidString)",
                rootDirectory: timelineFeatureTestCacheRoot("retry-visibility")),
            loader: NoopThumbnailLoader())
    }

    /// `ImageRenderer` takes a snapshot of the error screen, which renders from the model's recorded
    /// failure state. Whether lifecycle effects of the view (`onAppear`, `task`) run during a snapshot is not
    /// established: the failing run printed `[MetalGrid] activePath=metal`, which `onAppear` produces.
    private func renderedPixels(of model: TimelineViewModel, feed: ThumbnailFeed) throws -> [UInt8] {
        let view = TimelineView(model: model, feed: feed)
        return try RenderedInk.rawPixels(view, width: 480, height: 360)
    }

    /// Replays a first-load failure through the production reducer seam and renders its error screen.
    #if DEBUG
        private func renderReplayedFailure(message: String, retryable: Bool) throws -> [UInt8] {
            let feed = makeFeed()
            let model = TimelineViewModel(repository: NoopRepository(), feed: feed.feedCore)
            model.applyIsolatedInitialLoadEventsForTesting([.failed(message: message, retryable: retryable)])
            return try renderedPixels(of: model, feed: feed)
        }
    #endif

    private static func differingPixels(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        RenderedInk.differingPixelOffsets(lhs, rhs).count
    }

    /// Row of the first pixel that departs from the corner surface background. The centered error
    /// stack starts higher when it is taller, so this row moves up when the Retry button joins it.
    private static func firstInkRow(_ pixels: [UInt8]) -> Int {
        let background = (pixels[0], pixels[1], pixels[2])
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let departs =
                abs(Int(pixels[offset]) - Int(background.0)) > 8
                || abs(Int(pixels[offset + 1]) - Int(background.1)) > 8
                || abs(Int(pixels[offset + 2]) - Int(background.2)) > 8
            if departs { return offset / 4 / 480 }
        }
        return Int.max
    }

    private struct FailingStartupRepository: PhotosRepository {
        enum Failure: Error { case firstRead }
        func cachedTimeline() async -> [TimelineSection]? { nil }
        func loadTimeline() async throws -> [TimelineSection] { throw Failure.firstRead }
    }

    private struct NoopRepository: PhotosRepository {
        func cachedTimeline() async -> [TimelineSection]? { nil }
        func loadTimeline() async throws -> [TimelineSection] { [] }
    }

    private struct NoopThumbnailLoader: ThumbnailBatchLoader {
        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult { .delivered }
    }
}
