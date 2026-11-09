import Darwin
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// Live window resizing (Split View, Slide Over, Stage Manager) must keep one mounted grid, the
/// same top visible photo, the native tab bar, and a stable process footprint. The probe hosts the production
/// grid and chrome policies; the window frame is the only input that changes.
///
/// Set `ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR` (through `TEST_RUNNER_…`) to also write PNG snapshots per step.
final class MobileWindowGeometryTests: XCTestCase {
    @MainActor func testRepeatedWindowResizesKeepGridIdentityAndVisibleAnchor() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ThumbnailCache(rootDirectory: cacheDirectory)
        let feed = UIKitThumbnailFeed(cache: cache, loader: ChromeProbeLoader())
        let items = (0..<240).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "geometry-probe", nodeID: "\($0)"), captureTime: Date(),
                mediaType: "image/jpeg")
        }
        for (index, item) in items.enumerated() {
            let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.6, brightness: 0.7, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            }
            await cache.store(try XCTUnwrap(bitmap.jpegData(compressionQuality: 0.8)), for: item.uid)
        }
        _ = await feed.warmDecoded(items.map(\.uid))

        let fullBounds = scene.coordinateSpace.bounds
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let state = ChromeProbeState()
        state.showsLoadingCover = false
        state.showsActivity = false
        let window = UIWindow(windowScene: scene)
        window.frame = fullBounds
        window.rootViewController = UIHostingController(
            rootView: ChromeProbeShell(items: items, feed: feed, state: state))
        window.makeKeyAndVisible()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .seconds(2))

        let grid = try XCTUnwrap(descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.first)
        grid.scrollView.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
        try await Task.sleep(for: .milliseconds(500))
        let initialAnchor = try XCTUnwrap(grid.currentScrollAnchor())
        let residentBefore = residentMemoryBytes()

        // Regular and compact widths that iPadOS produces for Split View and Slide Over, then the full window
        // again, repeated to expose growth or identity loss. On iPhone the same fractions exercise the compact
        // range. This checks geometry changes, not hinge events or display handoff.
        let fractions: [CGFloat] = [1, 0.5, 0.34, 0.66, 1, 0.5, 1, 0.34, 1]
        var report: [String] = []
        // The tile side the grid showed the first time it had a given window width. The same width must show the same
        // density afterwards, whatever sequence of other widths came in between.
        var tileSideAtWidth: [CGFloat: CGFloat] = [:]
        // Main-run-loop callback cadence after each resize. This includes scheduling delays and is not GPU
        // presentation timing. Actual callback arrival avoids stale display timestamps across a resize.
        let cadence = FrameCadenceProbe()
        defer { cadence.invalidate() }
        let maximumFramesPerSecond = window.screen.maximumFramesPerSecond
        report.append("max_fps=\(maximumFramesPerSecond)")
        for cycle in 0..<3 {
            for (step, fraction) in fractions.enumerated() {
                let width = (fullBounds.width * fraction).rounded(.down)
                cadence.begin()
                let started = CFAbsoluteTimeGetCurrent()
                window.frame = CGRect(x: 0, y: 0, width: width, height: fullBounds.height)
                window.layoutIfNeeded()
                let layoutSeconds = CFAbsoluteTimeGetCurrent() - started
                try await Task.sleep(for: .milliseconds(350))
                let frames = cadence.summary()

                let grids = descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }
                XCTAssertEqual(grids.count, 1, "cycle \(cycle) step \(step): exactly one grid must stay mounted")
                XCTAssertTrue(grids.first === grid, "cycle \(cycle) step \(step): resize must not remount the grid")
                // Column changes can put another photo first in the same row. Measure the original photo itself,
                // not the row's first item, to detect actual viewport drift.
                let plan = try XCTUnwrap(grid.accessibilityFramePlan())
                let visible = plan.visibleSlots.map { grid.itemUIDs[$0.index] }
                XCTAssertTrue(
                    visible.contains(initialAnchor.itemID),
                    "cycle \(cycle) step \(step): the anchored photo must stay visible at a width of \(width)")
                let anchor = try XCTUnwrap(grid.currentScrollAnchor())
                let anchoredSlot = try XCTUnwrap(
                    plan.visibleSlots.first { grid.itemUIDs[$0.index] == initialAnchor.itemID })
                let anchoredY = anchoredSlot.slotRect.minY - grid.scrollView.contentOffset.y
                XCTAssertEqual(
                    anchoredY, initialAnchor.topOffset, accuracy: 1,
                    "cycle \(cycle) step \(step): the original photo must keep its viewport position at \(width)")
                let tileSide = anchoredSlot.slotRect.width
                let firstTileSide = tileSideAtWidth[width] ?? tileSide
                tileSideAtWidth[width] = firstTileSide
                XCTAssertEqual(
                    tileSide, firstTileSide, accuracy: 0.5,
                    "cycle \(cycle) step \(step): the grid must keep its density at a width of \(width)")
                report.append(
                    "cycle=\(cycle) step=\(step) anchor=\(anchor.itemID.nodeID) initial=\(initialAnchor.itemID.nodeID) anchored_y=\(anchoredY) initial_y=\(initialAnchor.topOffset) offset_y=\(grid.scrollView.contentOffset.y)"
                )
                XCTAssertEqual(grid.bounds.width, width, accuracy: 1)
                // iPhone keeps a UITabBar; iPadOS renders its top tab bar with a system container view.
                if UIDevice.current.userInterfaceIdiom == .phone {
                    let tabBar = try XCTUnwrap(descendants(window).compactMap { $0 as? UITabBar }.first)
                    XCTAssertFalse(tabBar.isHidden)
                }
                let navigationBar = try XCTUnwrap(descendants(window).compactMap { $0 as? UINavigationBar }.first)
                XCTAssertFalse(navigationBar.isHidden)
                report.append(
                    String(
                        format:
                            "cycle=%d step=%d width=%.0f layout_ms=%.2f first_callback_ms=%.2f settle_callbacks=%d settle_max_gap_ms=%.2f delayed_callback_gaps=%d",
                        cycle, step, width, layoutSeconds * 1000, frames.firstCallbackMs, frames.callbacks,
                        frames.maxGapMs, frames.delayedGaps))
                if cycle == 0 {
                    let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
                    snapshot(window, name: "resize-\(idiom)-\(Int(width))")
                }
            }
        }
        let residentAfter = residentMemoryBytes()
        report.append("resident_before_mb=\(residentBefore / 1_048_576) resident_after_mb=\(residentAfter / 1_048_576)")
        let text = report.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "resize-report"
        attachment.lifetime = .keepAlways
        add(attachment)
        writeSnapshotArtifact(name: "resize-report.txt", data: Data(text.utf8))
        // 27 resizes of the same content must not accumulate whole render surfaces; a generous bound catches leaks
        // without failing on simulator noise.
        XCTAssertLessThan(residentAfter, residentBefore + 96 * 1_048_576, text)
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func snapshot(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() {
            writeSnapshotArtifact(name: "\(name).png", data: data)
        }
    }

    private func writeSnapshotArtifact(name: String, data: Data) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else {
            return
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent(name))
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// Records actual main-run-loop callback arrival, relative to the display link's scheduled interval.
/// Adaptive refresh and simulator scheduling can affect these values; they do not prove displayed hitches.
@MainActor private final class FrameCadenceProbe {
    private var link: CADisplayLink?
    private var samples: [(arrival: CFTimeInterval, interval: CFTimeInterval)] = []
    private var windowStart: CFTimeInterval = 0

    init() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func begin() {
        samples.removeAll(keepingCapacity: true)
        windowStart = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        samples.append((CACurrentMediaTime(), link.targetTimestamp - link.timestamp))
    }

    func summary() -> (firstCallbackMs: Double, callbacks: Int, maxGapMs: Double, delayedGaps: Int) {
        var maxGap = 0.0
        var delayedGaps = 0
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            let gap = later.arrival - earlier.arrival
            let interval = max(earlier.interval, later.interval)
            maxGap = max(maxGap, gap)
            if interval > 0, gap > interval * 1.5 + 0.002 { delayedGaps += 1 }
        }
        let first = (samples.first?.arrival ?? CACurrentMediaTime()) - windowStart
        return (first * 1000, samples.count, maxGap * 1000, delayedGaps)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}
