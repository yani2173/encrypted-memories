#if os(macOS)
    import AppKit
    import PhotosCore
    import SwiftUI
    import XCTest

    @testable import UploadCore
    @testable import UploadFeature

    /// Measures the Mac Duplicates screen with 1,500 groups on the main thread: the first layout, scrolling while the
    /// library check and the ranking update the model, and opening the screen again. Runs only when
    /// `DUPLICATES_PERF_DIR` names an output directory; it writes `scrolling.marker` while it scrolls, so a profiler
    /// can attach, and its numbers to `measurement.txt`.
    @MainActor
    final class ExactDuplicatesPerformanceTests: XCTestCase {
        func testMeasureALongListWhileItScrollsAndOpensAgain() async throws {
            let path = ProcessInfo.processInfo.environment["DUPLICATES_PERF_DIR"]
            try XCTSkipIf(path == nil, "Set DUPLICATES_PERF_DIR to measure the long list.")
            let directory = URL(fileURLWithPath: path ?? "", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let scrollSeconds = Double(ProcessInfo.processInfo.environment["DUPLICATES_PERF_SECONDS"] ?? "") ?? 25
            let groups = (0..<1_500).map { index in
                ExactDuplicateGroup(
                    contentHash: String(format: "G%04d", index), hashKeyEpoch: "e",
                    members: (0..<3).map { PhotoUID(volumeID: "v", nodeID: "g\(index)-\($0)") })
            }
            let model = ExactDuplicatesModel(finder: ChurnFinder(groups: groups))
            var lines: [String] = []
            let clock = ContinuousClock()

            var start = clock.now
            var (window, host) = Self.host(model: model)
            for _ in 0..<1_000 where model.content != .groups { try await Task.sleep(for: .milliseconds(5)) }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            lines.append("first layout with \(model.groups.count) groups: \(Self.ms(start.duration(to: .now))) ms")

            let scrollView = try XCTUnwrap(Self.tallestScrollView(in: host), "no vertical scroll view")
            let marker = directory.appendingPathComponent("scrolling.marker")
            try Data().write(to: marker)
            var steps: [Duration] = []
            var y: CGFloat = 0
            let scrollStart = clock.now
            while scrollStart.duration(to: .now) < .seconds(scrollSeconds) {
                let step = clock.now
                y += 420
                let maxY = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
                if y > maxY { y = 0 }
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                // One frame for the model updates and SwiftUI's own work, as a person scrolling gives it.
                try await Task.sleep(for: .milliseconds(16))
                steps.append(step.duration(to: .now))
            }
            try? FileManager.default.removeItem(at: marker)
            let sorted = steps.sorted()
            lines.append(
                "scroll steps: \(steps.count) in \(scrollSeconds) s, median \(Self.ms(sorted[sorted.count / 2])) ms, "
                    + "p95 \(Self.ms(sorted[sorted.count * 95 / 100])) ms, max \(Self.ms(sorted.last ?? .zero)) ms, "
                    + "over 250 ms: \(steps.filter { $0 > .milliseconds(250) }.count)")
            lines.append("ranked groups after scrolling: \(model.groups.filter(\.isRanked).count)")

            for round in 1...3 {
                // Leaving the route drops the screen, opening it again builds it anew.
                start = clock.now
                window.orderOut(nil)
                window.contentView = nil
                lines.append("close \(round): \(Self.ms(start.duration(to: .now))) ms")
                try await Task.sleep(for: .milliseconds(200))
                start = clock.now
                (window, host) = Self.host(model: model)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                lines.append("open again \(round): \(Self.ms(start.duration(to: .now))) ms")
            }
            window.orderOut(nil)
            let report = lines.joined(separator: "\n") + "\n"
            try report.write(to: directory.appendingPathComponent("measurement.txt"), atomically: true, encoding: .utf8)
            print(report)
        }

        /// A vertical scroll over the copies of a group scrolls the list, for a row that fits and for a row that
        /// is wider than the column and scrolls sideways.
        func testAVerticalScrollOverTheCopiesScrollsTheList() async throws {
            let path = ProcessInfo.processInfo.environment["DUPLICATES_PERF_DIR"]
            try XCTSkipIf(path == nil, "Set DUPLICATES_PERF_DIR to drive the list.")
            let groups = (0..<60).map { index in
                ExactDuplicateGroup(
                    contentHash: String(format: "G%04d", index), hashKeyEpoch: "e",
                    members: (0..<(index == 1 ? 9 : 3)).map { PhotoUID(volumeID: "v", nodeID: "g\(index)-\($0)") })
            }
            let model = ExactDuplicatesModel(finder: ChurnFinder(groups: groups))
            let (window, host) = Self.host(model: model)
            defer { window.orderOut(nil) }
            for _ in 0..<1_000 where model.content != .groups { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let list = try XCTUnwrap(Self.tallestScrollView(in: host))
            var rows: [NSScrollView] = []
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll !== list { rows.append(scroll) }
                view.subviews.forEach(visit)
            }
            visit(host)
            let fitting = try XCTUnwrap(rows.first { ($0.documentView?.frame.width ?? 0) <= $0.frame.width + 1 })
            let wide = try XCTUnwrap(rows.first { ($0.documentView?.frame.width ?? 0) > $0.frame.width + 1 })
            for (name, row) in [("fitting", fitting), ("wide", wide)] {
                let listBefore = list.contentView.bounds.origin.y
                let rowBefore = row.contentView.bounds.origin
                // A trackpad gesture: continuous events with a began, changed, and ended phase.
                let phases: [NSEvent.Phase] = [.began, .changed, .changed, .changed, .changed, .ended]
                for phase in phases {
                    let event = try XCTUnwrap(
                        CGEvent(
                            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: phase == .ended ? 0 : -40, wheel2: 0, wheel3: 0))
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                    row.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
                    try await Task.sleep(for: .milliseconds(30))
                    XCTAssertEqual(
                        row.contentView.bounds.origin.y, rowBefore.y, "\(name): the row does not move up or down")
                }
                XCTAssertGreaterThan(list.contentView.bounds.origin.y, listBefore, "\(name): the list scrolls")
                XCTAssertEqual(
                    row.contentView.bounds.origin.y, rowBefore.y, "\(name): the row does not move up or down")
                list.contentView.scroll(to: .zero)
                list.reflectScrolledClipView(list.contentView)
            }
        }

        private static func ms(_ duration: Duration) -> Int {
            Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }

        private static func host(model: ExactDuplicatesModel) -> (NSWindow, NSView) {
            let view = ExactDuplicatesView(
                model: model, confirmsMergeAll: .constant(false), accent: .accentColor, cornerRadius: 6,
                onOpen: { _, _ in }
            ) { _ in
                RoundedRectangle(cornerRadius: 6).fill(Color.teal).frame(width: 132, height: 132)
            }
            .frame(width: 1400, height: 900)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            return (window, host)
        }

        /// The scroll view of the list: the tallest one, not a row of copies.
        private static func tallestScrollView(in view: NSView) -> NSScrollView? {
            var found: [NSScrollView] = []
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView { found.append(scroll) }
                view.subviews.forEach(visit)
            }
            visit(view)
            return found.max { $0.frame.height < $1.frame.height }
        }
    }

    /// 1,500 groups found at once, a library check that reports progress every 100 ms, and a ranking that answers
    /// each page after 50 ms, as a large library does while the person scrolls.
    private final class ChurnFinder: ExactDuplicateMerging, @unchecked Sendable {
        let groups: [ExactDuplicateGroup]

        init(groups: [ExactDuplicateGroup]) { self.groups = groups }

        func duplicateGroups(
            progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
        ) async throws -> ExactDuplicateScan {
            ExactDuplicateScan(
                groups: groups, coverage: .incomplete(unresolvedCount: 40),
                byteSizes: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Int64(4_200_000)) }))
        }

        func prepareIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws -> Bool {
            for completed in stride(from: 0, to: 60_000, by: 100) {
                await progress(.init(phase: .indexing, completed: completed, total: 60_000))
                try await Task.sleep(for: .milliseconds(100))
            }
            return false
        }

        func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
        }

        func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] {
            Dictionary(uniqueKeysWithValues: members.map { ($0, Date(timeIntervalSince1970: 1_749_456_000)) })
        }

        func rankMembers(
            of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
        ) async {
            try? await Task.sleep(for: .milliseconds(50))
            let facts = Dictionary(
                uniqueKeysWithValues: groups.map { group in
                    (
                        group.id,
                        Dictionary(
                            uniqueKeysWithValues: group.members.enumerated().map { index, member in
                                (
                                    member,
                                    ExactDuplicateKeepFacts(
                                        isInOwnAlbum: index == 0, isFavorite: index == 0, isNamedByManifest: false,
                                        captureDate: nil)
                                )
                            })
                    )
                })
            let fingerprints = Dictionary(
                uniqueKeysWithValues: groups.map { group in
                    (
                        group.id,
                        Dictionary(uniqueKeysWithValues: group.members.map { ($0, ExactDuplicateFingerprint()) })
                    )
                })
            await ranked(
                ExactDuplicateRankingPage(
                    members: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) }),
                    groupCount: groups.count, facts: facts, fingerprints: fingerprints))
        }

        func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
            requests.map { _ in .failure(CancellationError()) }
        }
    }
#endif
