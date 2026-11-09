import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// These probes use the production cover and actual UIKit frames. Additional safe-area insets are synthetic
/// system inputs; they do not simulate a native fold or a display handoff.
final class MobileViewerReservedRegionTests: XCTestCase {
    @MainActor func testPhotoViewerControlsAvoidTheDisplaysActiveCameraRegion() async throws {
        #if canImport(SwiftUI, _version: 8.0.85)
            guard #available(iOS 27.1, *) else { throw XCTSkip("Reserved regions need iOS 27.1") }
            let session = try await ClearanceSession.open()
            defer { session.close() }
            let viewer = try session.viewer
            let regions = viewer.view.reservedRegions(kind: .occlusion).filter(\.isActive)
            try XCTSkipIf(regions.isEmpty, "The current display reports no active camera region")
            let exclusions = regions.map { viewer.view.convert($0.frame, to: session.window) }
            let report = try session.assertClearance(exclusions: exclusions, stage: "active camera")
            let attachment = XCTAttachment(string: report)
            attachment.name = "viewer-camera-clearance"
            attachment.lifetime = .keepAlways
            add(attachment)
        #else
            throw XCTSkip("The SDK has no reserved regions")
        #endif
    }

    @MainActor func testPhotoViewerKeepsItsMediaAndFilmstripThroughSafeAreaChanges() async throws {
        let session = try await ClearanceSession.open()
        defer { session.close() }
        let viewer = try session.viewer
        let viewport = try session.photoViewport()
        let strip = try session.filmstrip()
        for insets in [
            UIEdgeInsets(top: 0, left: 80, bottom: 0, right: 0),
            UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 80),
            UIEdgeInsets(top: 70, left: 0, bottom: 0, right: 0),
            UIEdgeInsets(top: 0, left: 0, bottom: 70, right: 0),
            .zero,
        ] {
            viewer.additionalSafeAreaInsets = insets
            viewer.view.setNeedsLayout()
            try await session.waitForLayout()
            XCTAssertTrue(try session.photoViewport() === viewport, "Safe-area changes retain the same photo")
            XCTAssertTrue(try session.filmstrip() === strip, "Safe-area changes retain the same filmstrip")
            let safe = viewer.view.convert(viewer.view.safeAreaLayoutGuide.layoutFrame, to: session.window)
            let media = viewport.convert(viewport.bounds, to: session.window)
            let filmstrip = strip.convert(strip.bounds, to: session.window)
            XCTAssertGreaterThan(media.width, 0)
            XCTAssertGreaterThan(media.height, 0)
            for (name, frame) in [("media", media), ("filmstrip", filmstrip)] {
                XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 1, name)
                XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 1, name)
                XCTAssertGreaterThanOrEqual(frame.minY, safe.minY - 1, name)
                XCTAssertLessThanOrEqual(frame.maxY, safe.maxY + 1, name)
            }
        }
    }
}

@MainActor private final class ClearanceSession {
    let fixture: MobileSignedInFixture
    let window: UIWindow
    let root: UIHostingController<ClearancePresentation>
    let router: MobileViewerRouter
    let model: MobileLibraryModel
    private let previous: UIWindow?
    var viewer: UIViewController {
        get throws { try XCTUnwrap(root.presentedViewController, "The production router must present its viewer") }
    }

    static func open() async throws -> ClearanceSession {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let session = ClearanceSession(fixture: fixture, scene: scene)
        do {
            try await session.waitForLayout()
            _ = try session.photoViewport()
            _ = try session.filmstrip()
            return session
        } catch {
            session.close()
            throw error
        }
    }

    private init(fixture: MobileSignedInFixture, scene: UIWindowScene) {
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let router = MobileViewerRouter()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIHostingController(rootView: ClearancePresentation(router: router, model: model))
        self.fixture = fixture
        self.model = model
        self.router = router
        self.window = window
        self.root = root
        previous = scene.windows.first(where: \.isKeyWindow)
        window.rootViewController = root
        window.makeKeyAndVisible()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.presentation = MobileViewerPresentation(
                index: 2, items: fixture.items, context: ViewerCollectionContext(filter: .all),
                showsInfoInitially: false)
        }
    }

    func close() {
        root.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
        fixture.removeCache()
    }

    func waitForLayout() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var previous: [CGRect] = []
        var stablePasses = 0
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            if let presented = root.presentedViewController {
                presented.view.layoutIfNeeded()
                let frames = descendants(presented.view).compactMap { view -> CGRect? in
                    if let scroll = view as? UIScrollView, scroll.maximumZoomScale > scroll.minimumZoomScale {
                        return scroll.convert(scroll.bounds, to: window)
                    }
                    if view is MobileViewerFilmstripCollectionView { return view.convert(view.bounds, to: window) }
                    return nil
                }
                if frames.count >= 2, frames == previous { stablePasses += 1 } else { stablePasses = 0 }
                previous = frames
                if stablePasses >= 3 { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The photo viewport and filmstrip did not settle")
        throw ClearanceFailure.layout
    }

    func photoViewport() throws -> UIScrollView {
        let viewer = try self.viewer
        func pager(in controller: UIViewController) -> UIPageViewController? {
            if let pager = controller as? UIPageViewController { return pager }
            return controller.children.lazy.compactMap { pager(in: $0) }.first
        }
        let currentPage = try XCTUnwrap(pager(in: viewer)?.viewControllers?.first)
        return try XCTUnwrap(
            descendants(currentPage.view).compactMap { $0 as? UIScrollView }.first {
                $0.maximumZoomScale > $0.minimumZoomScale
            }, "The current production page must mount its zoomable photo")
    }

    func filmstrip() throws -> MobileViewerFilmstripCollectionView {
        try XCTUnwrap(descendants(try viewer.view).compactMap { $0 as? MobileViewerFilmstripCollectionView }.first)
    }

    func assertClearance(exclusions: [CGRect], stage: String) throws -> String {
        let viewer = try self.viewer
        let controls = visibleControls(in: viewer.view).map { ($0, $0.convert($0.bounds, to: window)) }
        XCTAssertGreaterThanOrEqual(controls.count, 3, "SETUP: measure multiple visible native viewer controls")
        for (control, frame) in controls {
            for exclusion in exclusions {
                XCTAssertFalse(
                    frame.intersects(exclusion),
                    "\(stage): \(type(of: control)) \(frame) overlaps \(exclusion)")
            }
        }
        let strip = try filmstrip()
        let stripFrame = strip.convert(strip.bounds, to: window)
        for exclusion in exclusions {
            XCTAssertFalse(stripFrame.intersects(exclusion), "The filmstrip avoids the camera")
        }
        let report =
            "\(stage) window=\(window.bounds) exclusions=\(exclusions) controls=\(controls.map(\.1)) filmstrip=\(stripFrame)"
        print(report)
        return report
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func visibleControls(in view: UIView) -> [UIControl] {
        guard !view.isHidden, view.alpha >= 0.01 else { return [] }
        let frame = view.convert(view.bounds, to: window)
        let own = (view as? UIControl).map { frame.intersects(window.bounds) && !frame.isEmpty ? [$0] : [] } ?? []
        return own + view.subviews.flatMap(visibleControls)
    }
}

private enum ClearanceFailure: Error { case layout }

private struct ClearancePresentation: View {
    let router: MobileViewerRouter
    let model: MobileLibraryModel
    var body: some View {
        Color.black.fullScreenCover(item: Binding(get: { router.presentation }, set: { router.presentation = $0 })) {
            presentation in
            MobilePhotoViewer(
                items: presentation.items, startIndex: presentation.index, context: presentation.context,
                libraryModel: model, viewerRouter: router, showsInfoInitially: presentation.showsInfoInitially)
        }
    }
}
