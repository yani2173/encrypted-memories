#if os(macOS)
    import AppKit
    import PhotosCore
    import SwiftUI
    import XCTest

    @testable import UploadCore
    @testable import UploadFeature

    /// The copies of a group in the Mac Duplicates screen: a row builds and loads only the copies on screen, and a
    /// row that fits takes no sideways scroll.
    @MainActor
    final class ExactDuplicateMembersRowTests: XCTestCase {
        func testAGroupOfAThousandCopiesLoadsOnlyTheCopiesOnScreen() async throws {
            let members = (0..<1_000).map { PhotoUID(volumeID: "v", nodeID: "copy-\($0)") }
            let loads = ThumbnailLoadLog()
            let (window, host) = try await Self.host(groups: [members], loads: loads)
            defer { window.orderOut(nil) }

            // The list column, at most 880 points wide, shows about six copies of 132 points.
            let first = loads.loadedUIDs
            XCTAssertTrue(first.contains(members[0]), "the first copy loads")
            XCTAssertLessThan(first.count, 40, "only the copies on screen and a few beside them load")

            // Scrolling the row builds and loads the copies that come on screen.
            let row = try XCTUnwrap(Self.rows(in: host).first)
            row.contentView.scroll(to: NSPoint(x: 142 * 500, y: 0))
            row.reflectScrolledClipView(row.contentView)
            host.layoutSubtreeIfNeeded()
            try await Self.settle(host)
            XCTAssertTrue(loads.loadedUIDs.contains(members[500]), "the copy scrolled to loads")
            XCTAssertLessThan(loads.loadedUIDs.count, 100, "the copies passed over without a stop are not built")
        }

        func testARowThatFitsTakesNoSidewaysScrollAndAWideRowDoes() async throws {
            let fitting = (0..<2).map { PhotoUID(volumeID: "v", nodeID: "fit-\($0)") }
            let wide = (0..<12).map { PhotoUID(volumeID: "v", nodeID: "wide-\($0)") }
            // More groups below make the list taller than the window, so it can scroll.
            let more = (0..<20).map { group in (0..<2).map { PhotoUID(volumeID: "v", nodeID: "more-\(group)-\($0)") } }
            let (window, host) = try await Self.host(groups: [fitting, wide] + more, loads: ThumbnailLoadLog())
            defer { window.orderOut(nil) }
            let list = try XCTUnwrap(Self.list(in: host))
            let rows = Self.rows(in: host)
            XCTAssertGreaterThanOrEqual(rows.count, 2)
            let byWidth = rows.sorted { ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0) }
            let fittingRow = try XCTUnwrap(byWidth.first)
            let wideRow = try XCTUnwrap(byWidth.last)

            XCTAssertLessThanOrEqual(
                fittingRow.documentView?.frame.width ?? 0, fittingRow.frame.width + 1, "two copies fit")
            XCTAssertGreaterThan(wideRow.documentView?.frame.width ?? 0, wideRow.frame.width + 1, "twelve do not")
            for (name, row, moves) in [("fitting", fittingRow, false), ("wide", wideRow, true)] {
                let before = row.contentView.bounds.origin.x
                // A trackpad gesture to the left: continuous events with a began, changed, and ended phase.
                for phase: NSEvent.Phase in [.began, .changed, .changed, .changed, .changed, .ended] {
                    let event = try XCTUnwrap(
                        CGEvent(
                            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0,
                            wheel2: phase == .ended ? 0 : -60, wheel3: 0))
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                    row.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
                    try await Task.sleep(for: .milliseconds(30))
                }
                if moves {
                    XCTAssertGreaterThan(row.contentView.bounds.origin.x, before, "\(name): the row scrolls")
                } else {
                    XCTAssertEqual(row.contentView.bounds.origin.x, before, "\(name): the row stays")
                }
            }

            // A vertical gesture over the row that fits scrolls the list, not the row.
            let listBefore = list.contentView.bounds.origin.y
            for phase: NSEvent.Phase in [.began, .changed, .changed, .changed, .changed, .ended] {
                let event = try XCTUnwrap(
                    CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                        wheel1: phase == .ended ? 0 : -40, wheel2: 0, wheel3: 0))
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                fittingRow.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertGreaterThan(list.contentView.bounds.origin.y, listBefore, "the list scrolls")
        }

        /// The Duplicates screen with real thumbnail tiles in a window as wide as a Mac screen.
        private static func host(
            groups: [[PhotoUID]], loads: ThumbnailLoadLog
        ) async throws -> (NSWindow, NSView) {
            let model = ExactDuplicatesModel(
                finder: RowFinder(
                    groups: groups.enumerated().map { index, members in
                        ExactDuplicateGroup(contentHash: "G\(index)", hashKeyEpoch: "e", members: members)
                    }))
            let thumbnails = ExactDuplicateThumbnails(
                read: { _ in nil },
                load: { uid in
                    loads.record(uid)
                    // The load waits like a slow download until the tile leaves the screen.
                    try? await Task.sleep(for: .seconds(600))
                })
            let view = ExactDuplicatesView(
                model: model, confirmsMergeAll: .constant(false), accent: .accentColor, cornerRadius: 6,
                onOpen: { _, _ in }
            ) { uid in
                ExactDuplicateThumbnail(uid: uid, side: 132, cornerRadius: 6, thumbnails: thumbnails)
            }
            .frame(width: 1400, height: 900)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<1_000 where model.visibleGroups.count != groups.count {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(model.visibleGroups.count, groups.count, "the screen shows the checked groups")
            try await settle(host)
            return (window, host)
        }

        /// Lays the screen out and gives the tiles' tasks time to start.
        private static func settle(_ host: NSView) async throws {
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }

        /// The scroll view of the list: the tallest one, not a row of copies.
        private static func list(in view: NSView) -> NSScrollView? {
            scrollViews(in: view).max { $0.frame.height < $1.frame.height }
        }

        /// The sideways scroll views of the copies, without the list itself.
        private static func rows(in view: NSView) -> [NSScrollView] {
            let list = list(in: view)
            return scrollViews(in: view).filter { $0 !== list }
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView { found.append(scroll) }
                view.subviews.forEach(visit)
            }
            visit(view)
            return found
        }
    }

    /// The photos whose thumbnail a tile started to load.
    @MainActor
    private final class ThumbnailLoadLog {
        private(set) var loadedUIDs: Set<PhotoUID> = []

        func record(_ uid: PhotoUID) { loadedUIDs.insert(uid) }
    }

    /// Finds the given groups at once and checks nothing else.
    private final class RowFinder: ExactDuplicateMerging, @unchecked Sendable {
        let groups: [ExactDuplicateGroup]

        init(groups: [ExactDuplicateGroup]) { self.groups = groups }

        func duplicateGroups(
            progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
        ) async throws -> ExactDuplicateScan {
            ExactDuplicateScan(groups: groups, coverage: .complete, byteSizes: [:])
        }

        func prepareIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws -> Bool {
            false
        }

        func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
        }

        /// Ranks every group at once, so the screen shows them.
        func rankMembers(
            of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
        ) async {
            let facts = Dictionary(
                uniqueKeysWithValues: groups.map { group in
                    (
                        group.id,
                        Dictionary(
                            uniqueKeysWithValues: group.members.map {
                                (
                                    $0,
                                    ExactDuplicateKeepFacts(
                                        isInOwnAlbum: false, isFavorite: false, isNamedByManifest: false,
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
