import AlbumCore
import AlbumsFeature
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// Measures the native picker in a resized test window; this does not simulate Split View or a fold.
final class MobileAlbumNarrowWindowTests: XCTestCase {
    /// Only a compact width with a regular height shows a sheet across the whole width.
    func testOnlyAPortraitPhoneSheetGoesWithoutTheBoundedSize() {
        XCTAssertTrue(AlbumPresentationTraits.usesRegularSizing(horizontal: .regular, vertical: .regular))
        XCTAssertTrue(AlbumPresentationTraits.usesRegularSizing(horizontal: .regular, vertical: .compact))
        XCTAssertTrue(AlbumPresentationTraits.usesRegularSizing(horizontal: .compact, vertical: .compact))
        XCTAssertFalse(AlbumPresentationTraits.usesRegularSizing(horizontal: .compact, vertical: .regular))
        XCTAssertFalse(AlbumPresentationTraits.usesRegularSizing(horizontal: nil, vertical: .regular))
    }

    /// iPhone landscape windows: a large iPhone has a regular width and keeps the popover, a smaller one has a compact
    /// width and adapts it to a sheet. Both keep a usable width; without the bound the picker shrank to 68 pt.
    @MainActor func testLandscapeWindowsKeepTheAlbumPickerUsable() async throws {
        let cases: [(CGSize, UIUserInterfaceSizeClass)] = [
            (CGSize(width: 956, height: 440), .regular),
            (CGSize(width: 874, height: 402), .compact),
        ]
        for (size, horizontal) in cases {
            let (window, picker) = try await presentPicker(in: size, horizontal: horizontal, vertical: .compact)
            print("[Album landscape window] window=\(window) horizontal=\(horizontal.rawValue) presented=\(picker)")
            XCTAssertGreaterThanOrEqual(picker.width, 300, "The picker must keep a usable width in \(size)")
            XCTAssertGreaterThanOrEqual(picker.minY, window.minY - 1)
            XCTAssertLessThanOrEqual(picker.maxY, window.maxY + 1, "The picker must fit the height of \(size)")
        }
    }

    /// Presents the album picker from the viewer's Add to Album button in a test window with the given size and
    /// size classes, and returns the window bounds and the presented frame. The window is removed again.
    @MainActor private func presentPicker(
        in size: CGSize, horizontal: UIUserInterfaceSizeClass, vertical: UIUserInterfaceSizeClass
    ) async throws -> (window: CGRect, picker: CGRect) {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let albums = MobileFixtureAlbums()
        let repository = AlbumsRepository(
            catalogBackend: albums, writeBackend: albums, capabilities: MobileFixtureAlbums.capabilities)
        let coordinator = AlbumActionCoordinator(repository: repository)
        let photo = PhotoUID(volumeID: "fixture", nodeID: "landscape-window")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.traitOverrides.horizontalSizeClass = horizontal
        window.traitOverrides.verticalSizeClass = vertical
        let root = UIHostingController(
            rootView: AlbumAddButton(coordinator: coordinator, photoUIDs: [photo], isPresented: .constant(true))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        root.traitOverrides.horizontalSizeClass = horizontal
        root.traitOverrides.verticalSizeClass = vertical
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await fulfillment(
            of: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "presentedViewController != nil"), object: root)
            ], timeout: 10)
        let presented = try XCTUnwrap(root.presentedViewController, "The album picker must open")
        // The fitted size settles after the presentation transition. Measure once it has ended and two layout passes
        // report the same frame.
        var frame = CGRect.null
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    guard !presented.isBeingPresented, presented.transitionCoordinator == nil else { return false }
                    presented.view.layoutIfNeeded()
                    let current = presented.view.convert(presented.view.bounds, to: window)
                    defer { frame = current }
                    return current == frame
                }
            }, object: nil)
        await fulfillment(of: [settled], timeout: 10)
        return (window.bounds, frame)
    }

    @MainActor func testCompactWindowKeepsAlbumPickerInsideAvailableWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let albums = MobileFixtureAlbums()
        let repository = AlbumsRepository(
            catalogBackend: albums, writeBackend: albums, capabilities: MobileFixtureAlbums.capabilities)
        let coordinator = AlbumActionCoordinator(repository: repository)
        let photo = PhotoUID(volumeID: "fixture", nodeID: "narrow-window")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        let root = UIHostingController(
            rootView: AlbumAddButton(coordinator: coordinator, photoUIDs: [photo], isPresented: .constant(true)))
        root.traitOverrides.horizontalSizeClass = .compact
        root.traitOverrides.verticalSizeClass = .regular
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await fulfillment(
            of: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "presentedViewController != nil"), object: root)
            ],
            timeout: 10)
        let presented = try XCTUnwrap(root.presentedViewController, "The album picker must be presented")
        let frame = presented.view.convert(presented.view.bounds, to: window)
        print("[Album narrow window] window=\(window.bounds) presented=\(frame)")
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, window.bounds.minX - 1)
        XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX + 1)

        root.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        let regularWindow = UIWindow(windowScene: scene)
        regularWindow.frame = CGRect(x: 0, y: 0, width: 400, height: 1000)
        regularWindow.traitOverrides.horizontalSizeClass = .regular
        let regularRoot = UIHostingController(
            rootView: AlbumAddButton(coordinator: coordinator, photoUIDs: [photo], isPresented: .constant(true))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        regularRoot.traitOverrides.horizontalSizeClass = .regular
        regularWindow.rootViewController = regularRoot
        regularWindow.makeKeyAndVisible()
        defer {
            regularRoot.presentedViewController?.dismiss(animated: false)
            regularWindow.isHidden = true
            regularWindow.rootViewController = nil
        }
        await fulfillment(
            of: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "presentedViewController != nil"), object: regularRoot)
            ], timeout: 10)
        let regularPicker = try XCTUnwrap(regularRoot.presentedViewController, "The regular album picker must open")
        let regularFrame = regularPicker.view.convert(regularPicker.view.bounds, to: regularWindow)
        print("[Album narrow window] regular window=\(regularWindow.bounds) presented=\(regularFrame)")
        XCTAssertGreaterThanOrEqual(regularFrame.width, 300, "The regular picker must have usable width")
        XCTAssertGreaterThan(regularFrame.height, 0)
        XCTAssertGreaterThanOrEqual(regularFrame.height, 380, "The regular picker must show its content")
        XCTAssertLessThanOrEqual(regularFrame.height, 391, "The regular picker must keep its height bounded")
        XCTAssertGreaterThanOrEqual(regularFrame.minX, regularWindow.bounds.minX - 1)
        XCTAssertLessThanOrEqual(regularFrame.maxX, regularWindow.bounds.maxX + 1)
    }
}
