import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit
import UploadCore
import XCTest

@testable import EncryptedMemoriesMobile

/// The series (burst) "Select Favorites" mode: Confirm offers "Keep Everything" or "Keep Only N Favorites".
///
/// The selection flow runs against `MobileSeriesFavoritesModel`, which the screen renders and which receives the
/// backend operation as a closure. The hosted screen test checks the native bars, the carousel and the filmstrip.
/// SwiftUI exposes no accessibility elements to a hosted test without assistive technology, so the viewer's
/// series button is verified at runtime.
final class MobileSeriesFavoritesTests: XCTestCase {
    // MARK: Selection flow

    @MainActor func testKeepEverythingClosesWithoutAnyBackendCall() {
        let probe = FlowProbe()
        let model = probe.makeModel(canKeepOnlyFavorites: true)

        model.confirm()
        XCTAssertEqual(probe.finished, [false], "Confirm without a mark only closes the mode")

        probe.finished.removeAll()
        model.toggleFavorite(probe.items[2].uid)
        model.confirm()
        XCTAssertTrue(model.showsKeepChoice, "a marked favorite makes Confirm offer the choice")
        XCTAssertTrue(probe.finished.isEmpty)

        model.keepEverything()
        XCTAssertEqual(probe.finished, [false])
        XCTAssertTrue(probe.keepOnlyCalls.isEmpty, "Keep Everything must not reach the backend")
    }

    @MainActor func testKeepOnlyFavoritesRunsTheOperationInSeriesOrderAndReportsTheDissolvedSeries() async {
        let probe = FlowProbe()
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[3].uid)
        model.toggleFavorite(probe.items[1].uid)

        await model.keepOnlyMarkedFavorites()

        XCTAssertEqual(probe.keepOnlyCalls, [[probe.items[1].uid, probe.items[3].uid]])
        XCTAssertEqual(probe.finished, [true], "the viewer closes because the series left the library")
        XCTAssertEqual(model.operation, .idle)
    }

    @MainActor func testAMemberWithoutAKnownRoleTellsThePersonThatItStayedBeforeTheModeCloses() async {
        let probe = FlowProbe()
        probe.keptMembersWithoutRole = 1
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[1].uid)

        await model.keepOnlyMarkedFavorites()

        XCTAssertEqual(model.operation, .finishedWithKeptMembers(count: 1))
        XCTAssertTrue(model.isPresentingKeptMembersNotice)
        XCTAssertTrue(probe.finished.isEmpty, "the mode stays open until the person read the notice")

        model.finishAfterKeptMembers()

        XCTAssertEqual(model.operation, .idle)
        XCTAssertEqual(probe.finished, [true], "after the notice the mode closes like a normal success")
    }

    @MainActor func testTheNoticeCannotBeDismissedTwice() {
        let probe = FlowProbe()
        probe.keptMembersWithoutRole = 2
        let model = probe.makeModel(canKeepOnlyFavorites: true)

        model.finishAfterKeptMembers()

        XCTAssertEqual(model.operation, .idle, "without a notice the mode must not close twice")
        XCTAssertTrue(probe.finished.isEmpty)
    }

    @MainActor func testFailureKeepsTheModeOpenAndRetryResumes() async {
        let probe = FlowProbe()
        probe.failuresBeforeSuccess = 1
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[0].uid)

        await model.keepOnlyMarkedFavorites()
        XCTAssertNotNil(model.failureMessage, "the failure is shown with a retry")
        XCTAssertTrue(probe.finished.isEmpty, "a failed operation must not close the mode or the viewer")
        XCTAssertTrue(model.selection.isFavorite(probe.items[0].uid), "the marks survive for the retry")

        await model.keepOnlyMarkedFavorites()
        XCTAssertNil(model.failureMessage)
        XCTAssertEqual(probe.keepOnlyCalls.count, 2, "the retry calls the journaled operation again")
        XCTAssertEqual(probe.finished, [true])
        XCTAssertEqual(probe.abandonCalls, 0, "a finished operation has nothing to abandon")
    }

    @MainActor func testFailureAlertUsesOnlyItsTypedReason() async {
        let probe = FlowProbe()
        probe.injectedFailure = SeriesDissolutionError.copyNotConfirmed
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[0].uid)

        await model.keepOnlyMarkedFavorites()

        let reason = SeriesDissolutionError.copyNotConfirmed.errorDescription ?? ""
        XCTAssertEqual(model.failureMessage, reason)
        XCTAssertEqual(model.failureAlertMessage, reason)
        XCTAssertTrue(model.canRetryFailure)
        XCTAssertEqual(probe.keepOnlyCalls.count, 1)
        XCTAssertTrue(model.selection.isFavorite(probe.items[0].uid))
        XCTAssertTrue(probe.finished.isEmpty)
    }

    @MainActor func testUnknownFailureHasAnEmptyBodyAndStillPresentsTheAlert() async {
        let probe = FlowProbe()
        probe.injectedFailure = NSError(
            domain: "ExampleSeriesFailure", code: 503,
            userInfo: [NSLocalizedDescriptionKey: "Example service diagnostic"])
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[0].uid)

        await model.keepOnlyMarkedFavorites()

        XCTAssertEqual(model.failureMessage, Optional.some(""))
        XCTAssertNotNil(model.failureMessage)
        XCTAssertTrue(model.failureMessage != nil)
        XCTAssertEqual(model.failureAlertMessage, "")
        XCTAssertTrue(model.canRetryFailure)
        XCTAssertEqual(probe.keepOnlyCalls.count, 1)
    }

    @MainActor func testInvalidSelectionDoesNotOfferRetry() async {
        let probe = FlowProbe()
        probe.injectedFailure = SeriesDissolutionError.invalidSelection
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[0].uid)

        await model.keepOnlyMarkedFavorites()

        XCTAssertFalse(model.canRetryFailure)
        XCTAssertEqual(model.failureMessage, SeriesDissolutionError.invalidSelection.errorDescription)
        XCTAssertEqual(probe.keepOnlyCalls.count, 1)
    }

    @MainActor func testAMissingLibraryServiceReportsItsOwnReasonAndOffersNoRetry() async {
        // The real route: a library model without a backend has no dissolution service. The failure is the
        // missing service, not an own-library refusal, and a retry cannot bring the service back.
        let libraryModel = MobileLibraryModel()
        let seriesUID = PhotoUID(volumeID: "fixture", nodeID: "series-0")
        do {
            try await libraryModel.keepOnlySeriesFavorites(
                seriesMainUID: seriesUID,
                seriesUIDs: [seriesUID],
                favoriteUIDs: [seriesUID]
            ) { _ in }
            XCTFail("Without a backend the operation must fail")
        } catch {
            let presentation = SeriesFailurePresentation(error: error)
            XCTAssertEqual(
                presentation.message, SeriesDissolutionError.libraryUnavailable.errorDescription
            )
            XCTAssertFalse(presentation.canRetry)
        }
    }

    @MainActor func testTheOwnLibraryRefusalKeepsItsReasonAndRetry() async {
        let probe = FlowProbe()
        probe.injectedFailure = SeriesDissolutionError.notOwnLibrary
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[0].uid)

        await model.keepOnlyMarkedFavorites()

        XCTAssertEqual(model.failureMessage, SeriesDissolutionError.notOwnLibrary.errorDescription)
        XCTAssertEqual(model.failureAlertMessage, SeriesDissolutionError.notOwnLibrary.errorDescription)
        XCTAssertTrue(model.canRetryFailure)
    }

    @MainActor func testTransientAndAmbiguousFailuresKeepRetryAndMarks() async {
        let failures: [SeriesDissolutionError] = [
            .notOwnLibrary, .alreadyRunning, .blockedByForeignDraft("example.jpg"),
            .copyNotConfirmed, .trashNotConfirmed,
        ]
        for failure in failures {
            let probe = FlowProbe()
            probe.injectedFailure = failure
            let model = probe.makeModel(canKeepOnlyFavorites: true)
            model.toggleFavorite(probe.items[0].uid)

            await model.keepOnlyMarkedFavorites()

            XCTAssertTrue(model.canRetryFailure)
            XCTAssertEqual(probe.keepOnlyCalls.count, 1)
            XCTAssertTrue(model.selection.isFavorite(probe.items[0].uid))
            XCTAssertTrue(probe.finished.isEmpty)
        }
    }

    @MainActor func testUnknownFailureRetriesOnlyOnRequestWithTheSameMarks() async {
        let probe = FlowProbe()
        probe.injectedFailure = NSError(domain: "ExampleSeriesFailure", code: 503)
        let model = probe.makeModel(canKeepOnlyFavorites: true)
        model.toggleFavorite(probe.items[0].uid)

        await model.keepOnlyMarkedFavorites()
        XCTAssertEqual(probe.keepOnlyCalls, [[probe.items[0].uid]])

        probe.injectedFailure = nil
        await model.keepOnlyMarkedFavorites()

        XCTAssertEqual(probe.keepOnlyCalls, [[probe.items[0].uid], [probe.items[0].uid]])
        XCTAssertEqual(probe.finished, [true])
        XCTAssertEqual(probe.abandonCalls, 0)
    }

    @MainActor func testLeavingTheModeAfterAFailureAbandonsThePendingOperation() async {
        for leave in [
            { (model: MobileSeriesFavoritesModel) in model.cancel() },
            { (model: MobileSeriesFavoritesModel) in model.keepEverything() },
        ] {
            let probe = FlowProbe()
            probe.failuresBeforeSuccess = 1
            let model = probe.makeModel(canKeepOnlyFavorites: true)
            model.toggleFavorite(probe.items[0].uid)
            await model.keepOnlyMarkedFavorites()
            model.dismissFailure()

            leave(model)

            XCTAssertEqual(probe.abandonCalls, 1, "no later activation may finish what the user left")
            XCTAssertEqual(probe.finished, [false])
        }

        let untouched = FlowProbe()
        untouched.makeModel(canKeepOnlyFavorites: true).cancel()
        XCTAssertEqual(untouched.abandonCalls, 0, "Cancel without an attempt touches no journal")
    }

    @MainActor func testSeriesOutsideTheOwnLibraryIsBrowseOnly() {
        let probe = FlowProbe()
        let model = probe.makeModel(canKeepOnlyFavorites: false)

        model.toggleFavorite(probe.items[0].uid)
        model.confirm()

        XCTAssertFalse(model.showsKeepChoice)
        XCTAssertTrue(model.selection.favoriteUIDs.isEmpty)
        XCTAssertTrue(probe.keepOnlyCalls.isEmpty)
    }

    // MARK: Hosted screens

    @MainActor func testSelectFavoritesScreenShowsBarActionsCarouselAndFilmstrip() async throws {
        let hosted = try await HostedLibrary()
        defer { hosted.tearDown() }
        let items = Array(hosted.fixture.items.prefix(5))
        let model = MobileSeriesFavoritesModel(
            request: MobileSeriesSelectionRequest(seriesMainUID: items[0].uid, items: items, focusedUID: items[1].uid),
            canKeepOnlyFavorites: true,
            keepOnlyFavorites: { _, _ in },
            abandonKeepOnlyFavorites: {},
            onFinished: { _ in }
        )
        let cover = CoverContent()
        try await hosted.install(CoverHost(cover: cover))
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) {
            cover.content = AnyView(MobileSeriesFavoritesScreen(model: model, libraryModel: hosted.libraryModel))
        }
        try await Task.sleep(for: .seconds(1))

        let screen = try XCTUnwrap(hosted.root.presentedViewController, "the mode is a full-screen cover")
        let bar = try XCTUnwrap(Self.firstView(of: UINavigationBar.self, in: screen.view))
        XCTAssertEqual(bar.topItem?.title, String(localized: "series.select_favorites_title"))
        XCTAssertFalse(Self.leadingItems(of: bar).isEmpty, "Cancel leads the bar")
        XCTAssertFalse(Self.trailingItems(of: bar).isEmpty, "Confirm trails the bar")
        let strip = try XCTUnwrap(Self.firstView(of: MobileViewerFilmstripCollectionView.self, in: screen.view))
        XCTAssertEqual(strip.numberOfItems(inSection: 0), items.count, "the filmstrip shows every photo of the series")
        XCTAssertTrue(
            Self.allViews(of: UIScrollView.self, in: screen.view).contains { !($0 is UICollectionView) },
            "the carousel pages horizontally above the filmstrip")
    }

    // MARK: Helpers

    /// SwiftUI places toolbar items in item groups on current iOS, not in the legacy bar button arrays.
    private static func leadingItems(of bar: UINavigationBar) -> [UIBarButtonItem] {
        guard let item = bar.topItem else { return [] }
        return (item.leftBarButtonItems ?? []) + item.leadingItemGroups.flatMap(\.barButtonItems)
    }

    private static func trailingItems(of bar: UINavigationBar) -> [UIBarButtonItem] {
        guard let item = bar.topItem else { return [] }
        return (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
    }

    private static func allViews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        let own = (root as? T).map { [$0] } ?? []
        return own + root.subviews.flatMap { allViews(of: type, in: $0) }
    }

    private static func firstView<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstView(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Depth-first search of UIKit's accessibility tree, which also contains SwiftUI's elements.
}

/// Records what the selection mode asks of its host.
@MainActor private final class FlowProbe {
    let items: [PhotoItem] = (0..<4).map { index in
        PhotoItem(
            uid: PhotoUID(volumeID: "fixture", nodeID: "series-\(index)"),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            mediaType: "image/jpeg")
    }
    var finished: [Bool] = []
    var keepOnlyCalls: [[PhotoUID]] = []
    var abandonCalls = 0
    var failuresBeforeSuccess = 0
    var injectedFailure: (any Error)?
    /// Members without a known role that the fake backend reports as staying in the library.
    var keptMembersWithoutRole = 0

    func makeModel(canKeepOnlyFavorites: Bool) -> MobileSeriesFavoritesModel {
        MobileSeriesFavoritesModel(
            request: MobileSeriesSelectionRequest(seriesMainUID: items[0].uid, items: items, focusedUID: items[0].uid),
            canKeepOnlyFavorites: canKeepOnlyFavorites,
            keepOnlyFavorites: { [self] favoriteUIDs, onProgress in
                keepOnlyCalls.append(favoriteUIDs)
                onProgress(.init(step: .copyingFavorite(index: 0, count: favoriteUIDs.count), fraction: 0.4))
                if keptMembersWithoutRole > 0 {
                    onProgress(.init(step: .membersStayedWithoutARole(count: keptMembersWithoutRole), fraction: 0.9))
                }
                if failuresBeforeSuccess > 0 {
                    failuresBeforeSuccess -= 1
                    throw SeriesDissolutionError.copyNotConfirmed
                }
                if let injectedFailure { throw injectedFailure }
                // The model records each report on the main actor, so let those hops land before this call returns.
                try? await Task.sleep(for: .milliseconds(50))
            },
            abandonKeepOnlyFavorites: { [self] in abandonCalls += 1 },
            onFinished: { [self] in finished.append($0) }
        )
    }
}

/// A key window with the signed-in fixture library. The installed root view presents the screen under test.
@MainActor private final class HostedLibrary {
    let fixture: MobileSignedInFixture
    let libraryModel = MobileLibraryModel()
    let root = UIHostingController(rootView: AnyView(Color.black))
    private let window: UIWindow
    private let previousKeyWindow: UIWindow?

    init() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        fixture.install(into: libraryModel)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
    }

    func install(_ host: some View) async throws {
        root.rootView = AnyView(host)
        try await Task.sleep(for: .milliseconds(300))
    }

    func tearDown() {
        root.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        fixture.removeCache()
    }
}

@MainActor @Observable private final class CoverContent {
    var content: AnyView?
}

private struct CoverHost: View {
    let cover: CoverContent

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .fullScreenCover(
                isPresented: Binding(get: { cover.content != nil }, set: { if !$0 { cover.content = nil } })
            ) {
                cover.content
            }
    }
}
