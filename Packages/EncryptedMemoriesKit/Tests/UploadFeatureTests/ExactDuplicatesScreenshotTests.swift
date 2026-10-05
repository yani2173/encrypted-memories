#if os(macOS)
    import AppKit
    import PhotosCore
    import SwiftUI
    import XCTest

    @testable import UploadCore
    @testable import UploadFeature

    /// Renders the Duplicates screen of macOS in light and dark for a visual review. Runs only when
    /// `DUPLICATES_SCREENSHOT_DIR` names an output directory, so the gates never depend on it.
    @MainActor
    final class ExactDuplicatesScreenshotTests: XCTestCase {
        private func outputDirectory() throws -> URL {
            let path = ProcessInfo.processInfo.environment["DUPLICATES_SCREENSHOT_DIR"]
            try XCTSkipIf(path == nil, "Set DUPLICATES_SCREENSHOT_DIR to render the screenshots.")
            let url = URL(fileURLWithPath: path ?? "", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func testRenderTheDuplicatesStates() async throws {
            let directory = try outputDirectory()
            let members = (0..<6).map { PhotoUID(volumeID: "v", nodeID: "photo-\($0)") }
            let groups = [
                ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: Array(members[0..<3])),
                ExactDuplicateGroup(contentHash: "B", hashKeyEpoch: "e", members: Array(members[3..<5])),
            ]
            let states: [(String, ScreenshotFinder)] = [
                ("checking", ScreenshotFinder(groups: [], coverage: .indexing, build: .counted)),
                ("ranking", ScreenshotFinder(groups: groups, coverage: .complete, build: .counted, holdsRanking: true)),
                (
                    "unchecked",
                    ScreenshotFinder(groups: groups, coverage: .incomplete(unresolvedCount: 12), build: .none)
                ),
            ]
            for (name, finder) in states {
                // The view starts the load itself, as the screen does when it opens.
                let model = ExactDuplicatesModel(finder: finder)
                let (window, host) = host(model: model)
                for _ in 0..<200 where !finder.isSettled(model) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(finder.isSettled(model), name)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(500))
                    let url = directory.appendingPathComponent(
                        "duplicates-macos-\(name)-\(appearance == .aqua ? "light" : "dark").png")
                    try capture(host, to: url)
                }
                window.orderOut(nil)
            }
        }

        private func host(model: ExactDuplicatesModel) -> (NSWindow, NSView) {
            let view = ExactDuplicatesView(model: model, confirmsMergeAll: .constant(false), accent: .accentColor) {
                uid in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hue: Double(abs(uid.nodeID.hashValue % 100)) / 100, saturation: 0.45, brightness: 0.8))
                    .frame(width: 120, height: 120)
            }
            .frame(width: 720, height: 520)
            // The Mac route draws the window background behind the screen, as `MacDuplicatesView` does.
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            return (window, host)
        }

        private func capture(_ host: NSView, to url: URL) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url)
        }
    }

    /// Fixed answers for one state of the screen. A held ranking or build never finishes while the screen renders.
    private final class ScreenshotFinder: ExactDuplicateMerging, @unchecked Sendable {
        enum Build { case none, counted }

        let groups: [ExactDuplicateGroup]
        let coverage: ExactDuplicateCoverage
        let build: Build
        let holdsRanking: Bool

        init(
            groups: [ExactDuplicateGroup], coverage: ExactDuplicateCoverage, build: Build, holdsRanking: Bool = false
        ) {
            self.groups = groups
            self.coverage = coverage
            self.build = build
            self.holdsRanking = holdsRanking
        }

        @MainActor func isSettled(_ model: ExactDuplicatesModel) -> Bool {
            guard model.content != .loading else { return false }
            if build == .counted, model.checkLine == nil { return false }
            if holdsRanking, model.rankingLine == nil { return false }
            if case .incomplete = coverage, model.uncheckedNote == nil { return false }
            return true
        }

        func duplicateGroups(
            progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
        ) async throws -> ExactDuplicateScan {
            ExactDuplicateScan(groups: groups, coverage: coverage, byteSizes: ["A": 4_200_000, "B": 18_400_000])
        }

        func prepareIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws -> Bool {
            guard build == .counted else { return false }
            await progress(.init(phase: .indexing, completed: 21_480, total: 51_220))
            try await Task.sleep(for: .seconds(3_600))
            return false
        }

        func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
        }

        func rankMembers(
            of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
        ) async {
            if holdsRanking {
                await ranked(ExactDuplicateRankingPage(members: [:], groupCount: 1))
                try? await Task.sleep(for: .seconds(3_600))
                return
            }
            await ranked(
                ExactDuplicateRankingPage(
                    members: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) }),
                    groupCount: groups.count))
        }

        func merge(
            _ requests: [(group: ExactDuplicateGroup, kept: PhotoUID)]
        ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
            requests.map { _ in .failure(CancellationError()) }
        }
    }
#endif
