#if os(macOS)
    import AppKit
    import MediaByteCache
    import MediaCache
    import PhotoViewerFeature
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
                ("groups", ScreenshotFinder(groups: groups, coverage: .complete, build: .none)),
                ("checking", ScreenshotFinder(groups: [], coverage: .indexing, build: .counted)),
                // Merge All waits for the facts of groups that nobody scrolled to; only then a progress row shows.
                ("merging", ScreenshotFinder(groups: groups, coverage: .complete, build: .counted, holdsRanking: true)),
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
                    if finder.holdsRanking, model.content == .groups, !model.isMerging {
                        Task { await model.mergeAll() }
                    }
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

        func testRenderNarrowAndLargeWaitingWindows() async throws {
            let directory = try outputDirectory()
            let members = (0..<4).map { PhotoUID(volumeID: "v", nodeID: "waiting-\($0)") }
            let groups = [
                ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: Array(members.prefix(2))),
                ExactDuplicateGroup(contentHash: "B", hashKeyEpoch: "e", members: Array(members.suffix(2))),
            ]
            for width in [CGFloat(240), 320, 480, 1600] {
                for scan in [true, false] {
                    let finder = ScreenshotFinder(
                        groups: groups, coverage: .complete, build: .none, holdsRanking: true, holdsScan: scan)
                    let model = ExactDuplicatesModel(finder: finder)
                    let (window, host) = host(model: model, width: width, height: 1000)
                    for _ in 0..<200 where !model.isCheckingGroups || (!scan && model.rankingLine == nil) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(model.isCheckingGroups)
                    XCTAssertFalse(model.canMerge)
                    window.appearance = NSAppearance(named: .aqua)
                    try await Task.sleep(for: .milliseconds(300))
                    try capture(
                        host,
                        to: directory.appendingPathComponent(
                            "duplicates-macos-waiting-\(Int(width))-\(scan ? "scan" : "ranking").png"))
                    model.retire()
                    window.orderOut(nil)
                    window.contentView = nil
                }
            }
        }

        /// The shared viewer of a group of duplicates with its filmstrip, next to the same viewer as the library opens
        /// it, and the viewer of a burst with the same filmstrip panel. The window toolbar with Keep This Copy and Merge
        /// belongs to the app and is not part of this render.
        func testRenderTheViewerOfAGroupNextToTheLibraryViewer() async throws {
            let directory = try outputDirectory()
            let members = (0..<3).map { PhotoUID(volumeID: "v", nodeID: "photo-\($0)") }
            let items = members.map {
                PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 1_749_456_000), mediaType: "image/png")
            }
            let burst = members.map {
                PhotoItem(
                    uid: $0, captureTime: Date(timeIntervalSince1970: 1_749_456_000), mediaType: "image/png",
                    tags: [.bursts], burstMemberIDs: members.map(\.nodeID))
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("duplicates-viewer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for (name, isGroup) in [("library", false), ("group", true), ("burst", false)] {
                let isBurst = name == "burst"
                let viewer = PhotoViewerModel(
                    items: isBurst ? burst : items, index: 1,
                    feed: ThumbnailFeed(
                        cache: ThumbnailCache(namespace: "duplicates-viewer-\(UUID().uuidString)", rootDirectory: root),
                        loader: ColorThumbnails()),
                    media: ColorMedia(), burstProvider: isBurst ? BurstMembers(items: burst) : nil)
                let view = PhotoViewerView(
                    model: viewer, onClose: {}, itemFilmstripLabel: isGroup ? "Identical copies" : nil
                )
                .frame(width: 1400, height: 900)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(1_500))
                    let url = directory.appendingPathComponent(
                        "duplicates-macos-viewer-\(name)-\(appearance == .aqua ? "light" : "dark").png")
                    try capture(host, to: url)
                }
                window.orderOut(nil)
                viewer.stop()
            }
        }

        /// The Mac route in a window with its toolbar: the screen runs under the toolbar and starts below it, as the
        /// route of the app lays it out. Rendered at the top and scrolled down, with the check still running.
        func testRenderTheListUnderTheWindowToolbar() async throws {
            let directory = try outputDirectory()
            let groups = (0..<40).map { index in
                ExactDuplicateGroup(
                    contentHash: index.isMultiple(of: 2) ? "A\(index)" : "B\(index)", hashKeyEpoch: "e",
                    members: (0..<(index.isMultiple(of: 3) ? 3 : 2)).map {
                        PhotoUID(volumeID: "v", nodeID: "photo-\(index)-\($0)")
                    })
            }
            let finder = ScreenshotFinder(groups: groups, coverage: .complete, build: .counted)
            let model = ExactDuplicatesModel(finder: finder)
            let controller = NSHostingController(rootView: ToolbarRoute(model: model))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1400, height: 900))
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<300 where !finder.isSettled(model) { try await Task.sleep(for: .milliseconds(10)) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                let style = appearance == .aqua ? "light" : "dark"
                for (place, offset) in [("top", CGFloat(0)), ("scrolled", 1_400)] {
                    if let scroll = Self.tallestScrollView(in: controller.view) {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset - scroll.contentInsets.top))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    try await Task.sleep(for: .milliseconds(800))
                    let url = directory.appendingPathComponent("duplicates-macos-toolbar-\(place)-\(style).png")
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
                    try capture.run()
                    capture.waitUntilExit()
                    XCTAssertEqual(capture.terminationStatus, 0, place)
                }
            }
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

        private func host(
            model: ExactDuplicatesModel, width: CGFloat = 1400, height: CGFloat = 900
        ) -> (NSWindow, NSView) {
            let view = ExactDuplicatesView(
                model: model, confirmsMergeAll: .constant(false), accent: .accentColor, cornerRadius: 6,
                onOpen: { _, _ in }
            ) { uid in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hue: Self.hue(of: uid), saturation: 0.45, brightness: 0.8))
                    .frame(width: 132, height: 132)
            }
            .frame(width: width, height: height)
            // The Mac route draws the window background behind the screen, as `MacDuplicatesView` does.
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            return (window, host)
        }

        /// A stable color for each photo, so the copies of a group look alike between runs.
        private static func hue(of uid: PhotoUID) -> Double {
            Double(uid.nodeID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 100) / 100
        }

        private func capture(_ host: NSView, to url: URL) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url)
        }
    }

    /// The Duplicates route as the Mac app lays it out: the screen runs under the window toolbar, and its scroll content
    /// starts below the toolbar height that the safe area reports.
    private struct ToolbarRoute: View {
        let model: ExactDuplicatesModel
        @State private var topInset: CGFloat = 0

        var body: some View {
            ZStack {
                ExactDuplicatesView(
                    model: model, confirmsMergeAll: .constant(false), accent: .accentColor, cornerRadius: 6,
                    onOpen: { _, _ in }
                ) { uid in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hue: Double(uid.nodeID.count % 7) / 7, saturation: 0.45, brightness: 0.8))
                        .frame(width: 132, height: 132)
                }
                .contentMargins(.top, topInset, for: .scrollContent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { topInset = geometry.safeAreaInsets.top }
                        .onChange(of: geometry.safeAreaInsets.top) { _, new in topInset = new }
                }
            )
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Text(L10n.string("duplicates.title")).font(.headline).fixedSize().padding(.horizontal, 12)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("duplicates.merge_all")) {}
                }
            }
        }
    }

    /// A plain color image for each photo, as PNG bytes.
    func colorPNG(for uid: PhotoUID, side: Int) -> Data {
        let hue = Double(uid.nodeID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 100) / 100
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.8, alpha: 1).setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    struct ColorThumbnails: ThumbnailBatchLoader {
        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            for uid in uids { onLoaded(uid, colorPNG(for: uid, side: 256)) }
            return .delivered
        }
    }

    struct ColorMedia: FullMediaProvider {
        func preview(for uid: PhotoUID) async throws -> Data { colorPNG(for: uid, side: 1_200) }
        func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
            colorPNG(for: uid, side: 1_200)
        }
    }

    /// Fixed answers for one state of the screen. A held ranking or build never finishes while the screen renders.
    private final class ScreenshotFinder: ExactDuplicateMerging, @unchecked Sendable {
        enum Build { case none, counted }

        let groups: [ExactDuplicateGroup]
        let coverage: ExactDuplicateCoverage
        let build: Build
        let holdsRanking: Bool
        let holdsScan: Bool

        init(
            groups: [ExactDuplicateGroup], coverage: ExactDuplicateCoverage, build: Build, holdsRanking: Bool = false,
            holdsScan: Bool = false
        ) {
            self.groups = groups
            self.coverage = coverage
            self.build = build
            self.holdsRanking = holdsRanking
            self.holdsScan = holdsScan
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
            if holdsScan { try await Task.sleep(for: .seconds(3_600)) }
            return ExactDuplicateScan(groups: groups, coverage: coverage, byteSizes: ["A": 4_200_000, "B": 18_400_000])
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

        /// Group A on one day, group B on two days.
        func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] {
            let day = Date(timeIntervalSince1970: 1_749_456_000)
            var dates: [PhotoUID: Date] = [:]
            for group in groups {
                for (index, member) in group.members.enumerated() where members.contains(member) {
                    let offset = group.id == "B" ? Double(index) * 86_400 * 5 : Double(index) * 60
                    dates[member] = day.addingTimeInterval(offset)
                }
            }
            return dates
        }

        func rankMembers(
            of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
        ) async {
            if holdsRanking {
                await ranked(ExactDuplicateRankingPage(members: [:], groupCount: 1))
                try? await Task.sleep(for: .seconds(3_600))
                return
            }
            // The first copy of A is a favorite in an album and backed up here; the second copy of B is shared.
            let facts: [String: [PhotoUID: ExactDuplicateKeepFacts]] = Dictionary(
                uniqueKeysWithValues: groups.map { group in
                    let memberFacts = group.members.enumerated().map { index, member in
                        (
                            member,
                            ExactDuplicateKeepFacts(
                                isInOwnAlbum: group.id == "A" && index == 0, isFavorite: group.id == "A" && index == 0,
                                isNamedByManifest: group.id == "A" && index == 0, captureDate: nil,
                                isShared: group.id == "B" && index == 1)
                        )
                    }
                    return (group.id, Dictionary(uniqueKeysWithValues: memberFacts))
                })
            let order = Dictionary(
                uniqueKeysWithValues: groups.map { group in
                    (group.id, group.id == "B" ? Array(group.members.reversed()) : group.members)
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
                    members: order, groupCount: groups.count, facts: facts, fingerprints: fingerprints))
        }

        func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
            requests.map { _ in .failure(CancellationError()) }
        }
    }
#endif

#if os(macOS)
    import Observation

    /// The thumbnail of a copy loads its image again after the shared tier dropped it while the tile was on screen.
    @MainActor
    final class ExactDuplicateThumbnailTests: XCTestCase {
        func testATileLoadsItsImageAgainAfterTheTierDroppedIt() async throws {
            let tier = FakeTier()
            let uid = PhotoUID(volumeID: "v", nodeID: "photo")
            let thumbnails = ExactDuplicateThumbnails(read: { tier.image(for: $0) }, load: { await tier.load($0) })
            let host = NSHostingView(
                rootView: ExactDuplicateThumbnail(uid: uid, side: 60, cornerRadius: 6, thumbnails: thumbnails))
            host.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<200 where tier.loads < 1 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(tier.loads, 1, "the tile loads its image")

            tier.evict(uid)

            for _ in 0..<200 where tier.loads < 2 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(tier.loads, 2, "the tile loads the dropped image again")
            XCTAssertTrue(tier.holds(uid))
        }

        func testATileWithoutAThumbnailDoesNotLoadInALoop() async throws {
            let tier = FakeTier(hasThumbnails: false)
            let uid = PhotoUID(volumeID: "v", nodeID: "photo")
            let thumbnails = ExactDuplicateThumbnails(read: { tier.image(for: $0) }, load: { await tier.load($0) })
            let host = NSHostingView(
                rootView: ExactDuplicateThumbnail(uid: uid, side: 60, cornerRadius: 6, thumbnails: thumbnails))
            host.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(tier.loads, 1, "a photo without a thumbnail loads once")
        }
    }

    /// The shared decoded tier: it holds images, loads them, and can drop them under memory pressure. Observed, so a
    /// dropped image redraws the tile, as a change of its group does in the app.
    @MainActor
    @Observable
    private final class FakeTier {
        private var held: Set<PhotoUID> = []
        private(set) var loads = 0
        private let hasThumbnails: Bool

        init(hasThumbnails: Bool = true) { self.hasThumbnails = hasThumbnails }

        func image(for uid: PhotoUID) -> Image? { held.contains(uid) ? Image(systemName: "photo") : nil }
        func holds(_ uid: PhotoUID) -> Bool { held.contains(uid) }
        func evict(_ uid: PhotoUID) { held.remove(uid) }

        func load(_ uid: PhotoUID) async {
            loads += 1
            if hasThumbnails { held.insert(uid) }
        }
    }
#endif

#if os(macOS)
    /// A copy that was not ready reads its readiness again when the library shows other photos, also when the host
    /// reads a library that is not observed.
    @MainActor
    final class ExactDuplicatesReadinessTests: XCTestCase {
        func testALibraryRevisionReadsTheReadinessOfTheCopiesAgain() async throws {
            let members = (0..<2).map { PhotoUID(volumeID: "v", nodeID: "photo-\($0)") }
            let finder = ScreenshotFinder(
                groups: [ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: members)],
                coverage: .complete, build: .none)
            let model = ExactDuplicatesModel(finder: finder)
            let library = UnobservedLibrary()
            let revision = LibraryRevision()
            let host = NSHostingView(rootView: ReadinessHost(model: model, library: library, revision: revision))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<300 where library.reads == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertGreaterThan(library.reads, 0, "the copies ask whether they can open")
            try await Task.sleep(for: .milliseconds(200))
            let before = library.reads

            library.shows = true
            revision.value &+= 1

            for _ in 0..<200 where library.reads == before { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertGreaterThan(library.reads, before, "a new library revision reads the readiness again")
        }
    }

    /// A library whose changes the screen does not observe, as the whole-library snapshot of the Mac timeline.
    @MainActor
    private final class UnobservedLibrary {
        var shows = false
        private(set) var reads = 0

        func canOpen(_ uid: PhotoUID) -> Bool {
            reads += 1
            return shows
        }
    }

    @MainActor
    @Observable
    private final class LibraryRevision {
        var value: UInt64 = 0
    }

    private struct ReadinessHost: View {
        let model: ExactDuplicatesModel
        let library: UnobservedLibrary
        let revision: LibraryRevision

        var body: some View {
            ExactDuplicatesView(
                model: model, confirmsMergeAll: .constant(false), accent: .accentColor, cornerRadius: 6,
                canOpen: { library.canOpen($0) }, libraryRevision: revision.value, onOpen: { _, _ in },
                cover: { _ in Color.teal.frame(width: 60, height: 60) })
        }
    }
#endif
