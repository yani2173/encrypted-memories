import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

final class MobilePrivacyPreviewShieldTests: XCTestCase {
    @MainActor func testInactivePreviewBlursContentWithoutTurningBlack() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.foregroundWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController()
        root.view.backgroundColor = .black
        let white = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        white.backgroundColor = .white
        root.view.addSubview(white)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let shield = MobilePrivacyPreviewShield()
        let uncovered = try brightnessStatistics(of: window)
        shield.update(enabled: true, isSceneActive: false, window: window)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertNotNil(cover.image, "The preview must contain a rendered image, not a fallback color")
        let covered = try brightnessStatistics(of: window)

        let uncoveredEdge = abs(uncovered.profile[29] - uncovered.profile[35])
        let coveredEdge = abs(covered.profile[29] - covered.profile[35])
        let coveredBroadContrast = abs(covered.profile[8] - covered.profile[56])
        XCTAssertGreaterThan(uncoveredEdge, 0.7, "The negative control must show a sharp edge")
        XCTAssertGreaterThan(coveredBroadContrast, 0.65, "Blur must preserve broad light and dark regions")
        XCTAssertLessThan(coveredEdge, coveredBroadContrast * 0.75, "The covered edge must be softened")
        XCTAssertEqual(covered.average, uncovered.average, accuracy: 0.05, "Blur must not whiten or darken the preview")
        shield.remove()
    }

    @MainActor func testProductionMetalGridRetainsItsColorsInTheBlurredPreview() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.foregroundWindowScene)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        // Put distinct fixture colors next to each other, starting with the brightest thumbnails.
        let items = (0..<6).reversed().flatMap { index in fixture.sections.map { $0.items[index] } }
        let state = ChromeProbeState()
        state.showsLoadingCover = false
        state.showsActivity = false
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(
            rootView: ChromeProbeShell(items: items, feed: fixture.feed, state: state))
        window.makeKeyAndVisible()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        var probes: [(point: CGPoint, rgb: [Double])] = []
        var ready = false
        for _ in 0..<100 {
            if let grid = descendants(window).compactMap({ $0 as? UIKitTimelineGridHostView }).first,
                let plan = grid.accessibilityFramePlan()
            {
                probes = plan.visibleSlots.compactMap { slot in
                    let rect = grid.metalView.convert(slot.viewportRect, to: window)
                    // The probe reads the pixel at the center of the tile, so that point must lie clear of the bars.
                    // A tile taller than the clear band, like 233 pt tiles on the 678 pt outer display of iPhone Duo,
                    // still gives a probe when its center is clear.
                    guard rect.midY > 140, rect.midY < window.bounds.height - 100 else { return nil }
                    let item = items[slot.index]
                    guard let section = fixture.sections.firstIndex(where: { $0.items.contains(item) }),
                        let index = fixture.sections[section].items.firstIndex(of: item)
                    else { return nil }
                    var red: CGFloat = 0
                    var green: CGFloat = 0
                    var blue: CGFloat = 0
                    var alpha: CGFloat = 0
                    UIColor(
                        hue: CGFloat(section) / 6, saturation: 0.55,
                        brightness: 0.45 + 0.5 * CGFloat(index % 6) / 6, alpha: 1
                    )
                    .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    return (
                        CGPoint(x: rect.midX / window.bounds.width, y: rect.midY / window.bounds.height),
                        [Double(red), Double(green), Double(blue)]
                    )
                }
                if probes.count >= 3, try matchesFixtureColors(snapshot(of: window), probes: probes, tolerance: 0.12) {
                    ready = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(ready, "Actual pixels must show the known fixture colors before testing blur")
        guard ready else { return }
        let shield = MobilePrivacyPreviewShield()
        defer { shield.remove() }
        shield.update(enabled: true, isSceneActive: false, window: window)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        let image = try XCTUnwrap(cover.image, "Capturing the production Metal grid must succeed")
        XCTAssertTrue(
            try matchesFixtureColors(snapshot(of: window), probes: probes, tolerance: 0.18),
            "Blur must retain the photo colors at their actual grid positions")
        // A uniform card can have the correct average brightness. It must still fail this spatial oracle.
        for color in [UIColor.gray, UIColor(white: 0.08, alpha: 1)] {
            let flat = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            XCTAssertFalse(
                try matchesFixtureColors(flat, probes: probes, tolerance: 0.18),
                "Uniform and missing-grid previews must fail the same acceptance check")
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "production-metal-grid-blurred-preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func snapshot(of window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func matchesFixtureColors(
        _ image: UIImage, probes: [(point: CGPoint, rgb: [Double])], tolerance: Double
    ) throws -> Bool {
        let source = try XCTUnwrap(image.cgImage)
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return probes.allSatisfy { probe in
            let x = min(side - 1, max(0, Int(probe.point.x * Double(side))))
            let y = min(side - 1, max(0, Int(probe.point.y * Double(side))))
            return (0..<3).allSatisfy { channel in
                abs(Double(pixels[(y * side + x) * 4 + channel]) / 255 - probe.rgb[channel]) < tolerance
            }
        }
    }

    @MainActor private func brightnessStatistics(of window: UIWindow) throws -> (average: Double, profile: [Double]) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let values = try pixels.withUnsafeMutableBytes { buffer in
            let bitmap = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.interpolationQuality = .high
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return stride(from: 0, to: buffer.count, by: 4).map { index in
                Double(Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2])) / (3 * 255)
            }
        }
        let profile = (0..<side).map { x in
            (0..<side).reduce(0) { brightness, y in brightness + values[y * side + x] } / Double(side)
        }
        return (values.reduce(0, +) / Double(values.count), profile)
    }

    /// Reads the paused fade's on-screen opacity. The caller must pause the fade first; a paused fade holds
    /// this value between its start and end, so the check is deterministic even on a loaded test machine.
    @MainActor private func assertMidFade(
        _ cover: UIView, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let opacity = try XCTUnwrap(cover.layer.presentation(), file: file, line: line).opacity
        XCTAssertGreaterThan(opacity, 0, file: file, line: line)
        XCTAssertLessThan(opacity, 1, "the cover must be between its start and end", file: file, line: line)
    }

    /// Waits until the cover's presentation layer exists. The layer materializes only after the runloop
    /// committed the animation and rendered the first frame. The caller must pause the fade first, so the
    /// polls below cannot let the fade complete the way the old fixed sleeps did on loaded hosted runners.
    @MainActor private func waitForFirstFrame(of cover: UIView) async throws {
        let deadline = ContinuousClock.now + .milliseconds(300)
        while cover.layer.presentation() == nil {
            if ContinuousClock.now > deadline {
                XCTFail("The cover never rendered its first frame")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Pauses the active fade at half progress so a test can react mid-fade without wall-clock sleeps.
    @MainActor private func pauseFadeMidway(_ shield: MobilePrivacyPreviewShield) throws {
        let fade = try XCTUnwrap(shield.animator, "The fade must still be running when the test interrupts it")
        fade.pauseAnimation()
        fade.fractionComplete = 0.5
    }

    /// Delivers the fade's natural completion immediately: the fade jumps to its end state and its completion
    /// handler runs synchronously. This models a runner whose sleep returns after the fade already finished.
    /// A bare stopAnimation(false) leaves the animator un-finalized and throws when it is released, so the
    /// finishAnimation(at:) call is required.
    @MainActor private func finishFade(_ fade: UIViewPropertyAnimator) {
        fade.pauseAnimation()
        fade.fractionComplete = 1.0
        fade.stopAnimation(false)
        fade.finishAnimation(at: .end)
    }

    @MainActor func testPreviewFadesInAndOutAndSurvivesRapidReactivation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .red
        window.makeKeyAndVisible()
        let shield = MobilePrivacyPreviewShield()
        defer {
            shield.remove()
            window.isHidden = true
            previous?.makeKey()
        }

        shield.update(enabled: true, isSceneActive: false, window: window, animated: true)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertFalse(
            cover.layer.animationKeys()?.isEmpty ?? true, "Deactivation must fade instead of appearing instantly")
        // Pause synchronously, before any await: a 5 ms poll on a loaded runner can wake after the 160 ms
        // fade finished, and a completed fade clears the animator the pause below needs.
        try pauseFadeMidway(shield)
        try await waitForFirstFrame(of: cover)
        try assertMidFade(cover)
        shield.prepareForSnapshot()
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertTrue(cover.layer.animationKeys()?.isEmpty ?? true)

        shield.update(enabled: true, isSceneActive: true, window: window, animated: true)
        XCTAssertNotNil(cover.superview, "Activation must keep the cover until its fade finishes")
        XCTAssertFalse(cover.layer.animationKeys()?.isEmpty ?? true, "Activation must fade the cover out")
        try pauseFadeMidway(shield)
        try await waitForFirstFrame(of: cover)
        try assertMidFade(cover)
        shield.update(enabled: true, isSceneActive: false, window: window, animated: true)
        shield.prepareForSnapshot()
        // prepareForSnapshot stops the running fade-in, so no delayed completion can remove this cover later.
        XCTAssertTrue(cover.superview === window, "An old fade-out must not remove a new privacy cover")
        XCTAssertEqual(cover.alpha, 1)

        shield.update(enabled: true, isSceneActive: true, window: window, animated: true)
        finishFade(try XCTUnwrap(shield.animator, "Activation must start a fade-out"))
        XCTAssertNil(cover.superview)
    }

    /// When re-deactivation arrives after the fade-out already finished, the old cover was removed and a new
    /// cover takes its place. The window must still end up covered; the old reference is stale by design.
    @MainActor func testRedeactivationAfterCompletedFadeOutReplacesTheCover() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .red
        window.makeKeyAndVisible()
        let shield = MobilePrivacyPreviewShield()
        defer {
            shield.remove()
            window.isHidden = true
            previous?.makeKey()
        }

        shield.update(enabled: true, isSceneActive: false, window: window, animated: true)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        shield.prepareForSnapshot()
        XCTAssertEqual(cover.alpha, 1)

        // Finish the fade-out before the scene is deactivated again.
        shield.update(enabled: true, isSceneActive: true, window: window, animated: true)
        let fadeOut = try XCTUnwrap(shield.animator, "Activation must start a fade-out")
        finishFade(fadeOut)
        XCTAssertNil(cover.superview, "A completed fade-out must remove its cover")

        shield.update(enabled: true, isSceneActive: false, window: window, animated: true)
        let replacement = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertFalse(replacement === cover, "Re-deactivation after a completed fade-out must install a new cover")
        shield.prepareForSnapshot()
        XCTAssertTrue(replacement.superview === window, "The new cover must cover the window")
        XCTAssertEqual(replacement.alpha, 1, "The new cover must be fully opaque before a snapshot")
    }

    @MainActor func testBackgroundNotificationFinishesTheFadeBeforeTheSnapshot() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let original = UserDefaults.standard.object(forKey: AppSettingsKey.blurAppPreview)
        UserDefaults.standard.set(true, forKey: AppSettingsKey.blurAppPreview)
        let center = MobilePrivacyPreviewShieldCenter()
        defer {
            center.refreshAll(enabled: false)
            UserDefaults.standard.set(original, forKey: AppSettingsKey.blurAppPreview)
            window.isHidden = true
            previous?.makeKey()
        }
        center.register(window: window)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertTrue(cover.layer.animationKeys()?.isEmpty ?? true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(cover.layer.presentation()?.opacity ?? 1, 1)
    }

    @MainActor func testInactiveSceneCoversItsWindowAndActiveSceneRestoresIt() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let shield = MobilePrivacyPreviewShield()

        shield.update(enabled: false, isSceneActive: false, window: window)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)

        shield.update(enabled: true, isSceneActive: false, window: window)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)

        shield.update(enabled: true, isSceneActive: true, window: window)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }

    @MainActor func testEachSceneOwnsItsShield() {
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let secondWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let firstShield = MobilePrivacyPreviewShield()
        let secondShield = MobilePrivacyPreviewShield()

        firstShield.update(enabled: true, isSceneActive: false, window: firstWindow)
        secondShield.update(enabled: true, isSceneActive: true, window: secondWindow)

        XCTAssertEqual(firstWindow.subviews.compactMap { $0 as? UIImageView }.count, 1)
        XCTAssertTrue(secondWindow.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }

    @MainActor func testCenterRetainsWindowShieldAfterPresentationAnchorDetaches() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let center = MobilePrivacyPreviewShieldCenter()

        center.register(window: window)
        center.refreshAll(enabled: true)

        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)
        // A full-screen cover can remove the SwiftUI anchor without destroying its scene window.
        center.refreshAll(enabled: true)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)

        center.refreshAll(enabled: false)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }

    @MainActor func testCenterUpdatesEveryRegisteredWindowWhenPreferenceChanges() {
        let windows = (0..<2).map { _ in UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        let center = MobilePrivacyPreviewShieldCenter()
        for window in windows { center.register(window: window) }

        center.refreshAll(enabled: true)
        XCTAssertTrue(windows.allSatisfy { $0.subviews.compactMap { $0 as? UIImageView }.count == 1 })

        center.refreshAll(enabled: false)
        XCTAssertTrue(windows.allSatisfy { $0.subviews.compactMap { $0 as? UIImageView }.isEmpty })
    }

    @MainActor func testSceneLifecycleCoversAndRestoresTheRegisteredWindow() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.foregroundWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        let original = UserDefaults.standard.object(forKey: AppSettingsKey.blurAppPreview)
        UserDefaults.standard.set(true, forKey: AppSettingsKey.blurAppPreview)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: AppSettingsKey.blurAppPreview)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettingsKey.blurAppPreview)
            }
            window.isHidden = true
        }

        let center = MobilePrivacyPreviewShieldCenter()
        center.register(window: window)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)

        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }
}
