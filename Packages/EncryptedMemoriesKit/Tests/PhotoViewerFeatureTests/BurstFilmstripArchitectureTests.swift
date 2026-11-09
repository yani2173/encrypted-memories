import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerCore
import PhotosCore
import XCTest

@testable import PhotoViewerFeature

final class BurstFilmstripArchitectureTests: XCTestCase {
    func testShortCallFormReloadsOnlyOnIdentityChangeNotSelection() {
        let uids = [PhotoUID(volumeID: "v", nodeID: "a"), PhotoUID(volumeID: "v", nodeID: "b")]
        let update = BurstFilmstripUpdatePolicy.resolve(
            previousItems: uids,
            currentItems: uids,
            previousSelectedUID: uids[0],
            currentSelectedUID: uids[1]
        )
        XCTAssertFalse(update.reloadData, "same UIDs must not trigger a full reload")
        XCTAssertTrue(update.selectCurrent, "a selection change must still move the native selection")
    }

    @MainActor
    func testViewerSeedsKnownBurstMembersBeforeProviderResponse() async {
        let root = Self.cacheRoot("burst-filmstrip")
        let items = [
            makeItem("a", burstMembers: ["a", "b", "c"]),
            makeItem("b", burstMembers: ["a", "b", "c"]),
            makeItem("c", burstMembers: ["a", "b", "c"]),
        ]
        let model = PhotoViewerModel(
            items: items,
            index: 1,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-filmstrip-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: EmptyBurstProvider()
        )
        model.start()
        defer { model.stop() }

        XCTAssertTrue(model.hasBurstFilmstrip)
        XCTAssertEqual(model.burstItems.map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(model.burstIndex, 1)

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.hasBurstFilmstrip, "An empty provider response must not clear a known timeline burst group")

        model.selectBurstIndex(2)
        XCTAssertEqual(model.current.uid.nodeID, "c")
        XCTAssertEqual(model.exportItemsForDownload.map(\.uid.nodeID), ["a", "b", "c"])
    }

    @MainActor
    func testContextualNavigationPrefersFilmstripThenFallsThroughToLibrary() async {
        let root = Self.cacheRoot("burst-navigation")
        let title = makeItem("b", burstMembers: ["a", "b", "c"])
        let nextLibraryItem = makeItem("d", burstMembers: [])
        let burst = [
            makeItem("a", burstMembers: ["a", "b", "c"]),
            title,
            makeItem("c", burstMembers: ["a", "b", "c"]),
        ]
        let model = PhotoViewerModel(
            items: [title, nextLibraryItem],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-navigation-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: StaticBurstProvider(items: burst)
        )
        model.start()
        defer { model.stop() }

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.hasBurstFilmstrip)
        XCTAssertEqual(model.current.uid.nodeID, "b")
        XCTAssertEqual(model.index, 0)

        model.nextInContext()
        XCTAssertEqual(model.current.uid.nodeID, "c")
        XCTAssertEqual(model.index, 0, "Right arrow should stay inside the series before changing library item")

        model.nextInContext()
        XCTAssertEqual(model.current.uid.nodeID, "d")
        XCTAssertEqual(model.index, 1, "At the series edge, right arrow should fall through to the next library item")
    }

    @MainActor
    func testUIDPageSelectionUsesFullIdentityAndResetsNestedBurstSelection() async {
        let root = Self.cacheRoot("uid-page-selection")
        let first = makeItem("same", burstMembers: [])
        let second = PhotoItem(
            uid: PhotoUID(volumeID: "other-volume", nodeID: "same"),
            captureTime: Date(timeIntervalSince1970: 2),
            mediaType: "image/jpeg"
        )
        let model = PhotoViewerModel(
            items: [first, second],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "uid-page-selection-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider()
        )
        model.start()
        defer { model.stop() }

        XCTAssertTrue(model.selectPage(uid: second.uid))
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.current.uid, second.uid)
        XCTAssertFalse(model.selectPage(uid: PhotoUID(volumeID: "missing", nodeID: "same")))
        XCTAssertEqual(model.index, 1)
    }

    @MainActor
    func testViewerDownloadAfterAFailedReadReadsTheWholeBurstAgain() async {
        let members = ["a", "b", "c"]
        // Member "b" carries no burst tags, like a series photo that is not the main photo, so
        // an export from it alone would not read the group again.
        let plainMember = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "b"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        let complete = [makeItem("a", burstMembers: members), plainMember, makeItem("c", burstMembers: members)]
        XCTAssertFalse(plainMember.isBurstCandidate)
        // Opened alone, and opened next to a second member, which seeds a partial filmstrip.
        let openedPages: [(String, [PhotoItem])] = [
            ("burst opened alone", [complete[0]]),
            ("burst with a partial filmstrip", Array(complete.prefix(2))),
        ]
        for (name, pages) in openedPages {
            let model = PhotoViewerModel(
                items: pages,
                index: 0,
                feed: ThumbnailFeed(
                    cache: ThumbnailCache(
                        namespace: "burst-failed-download-\(UUID().uuidString)",
                        rootDirectory: Self.cacheRoot("burst-failed-download")),
                    loader: EmptyThumbnailLoader()
                ),
                media: FailingMediaProvider(),
                burstProvider: FailingBurstProvider()
            )
            model.start()
            defer { model.stop() }
            XCTAssertTrue(model.isLoadingBurst, "opening a burst page starts its read: \(name)")

            // The provider read throws, so wait until the filmstrip settles as failed.
            for _ in 0..<200 where model.isLoadingBurst {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.isLoadingBurst, "the failed read must end the loading state: \(name)")
            XCTAssertEqual(model.burstItems.count, pages.count > 1 ? 2 : 0, name)
            if pages.count > 1 {
                // The person steps the filmstrip to the member without burst tags.
                model.selectBurstIndex(1)
                XCTAssertEqual(model.current, plainMember, name)
            }

            // Download stays available and hands the page's main photo, never the shown member
            // or the partial filmstrip, to the export route.
            XCTAssertTrue(model.canDownloadCurrentSelection, name)
            XCTAssertEqual(model.exportItemsForDownload, [complete[0]], name)

            // The export route (`MainView.makeExportRequest`) reads the group again: with the
            // network back it exports the whole burst ...
            let recovered = await BurstExportExpansion.expand(
                sourceItems: model.exportItemsForDownload,
                preferredSeriesNameSource: model.baseCurrent,
                burstGroupReader: { _ in complete }
            )
            XCTAssertEqual(recovered, .success(items: complete, expandedSingleSeries: true), name)

            // ... and while it is still offline it reports the burst failure, which the Mac
            // shows with the existing burst export alert.
            let stillOffline = await BurstExportExpansion.expand(
                sourceItems: model.exportItemsForDownload,
                preferredSeriesNameSource: model.baseCurrent,
                burstGroupReader: { _ in throw TestError.unavailable }
            )
            XCTAssertEqual(stillOffline, .burstReadFailed(failedSources: [complete[0]]), name)
        }
    }

    @MainActor
    func testViewerDownloadOfAPartlySeededBurstReadsAgainWhenTheGroupAnswerIsIncomplete() async {
        let members = ["a", "b", "c"]
        let complete = members.map { makeItem($0, burstMembers: members) }
        // The page holds two of the three members; the provider answers with no photo, or with
        // the page photo only.
        for (name, answer) in [("empty answer", [PhotoItem]()), ("single-photo answer", [complete[0]])] {
            let model = PhotoViewerModel(
                items: Array(complete.prefix(2)),
                index: 0,
                feed: ThumbnailFeed(
                    cache: ThumbnailCache(
                        namespace: "burst-unconfirmed-download-\(UUID().uuidString)",
                        rootDirectory: Self.cacheRoot("burst-unconfirmed-download")),
                    loader: EmptyThumbnailLoader()
                ),
                media: FailingMediaProvider(),
                burstProvider: StaticBurstProvider(items: answer)
            )
            model.start()
            defer { model.stop() }
            XCTAssertTrue(model.isLoadingBurst, "opening a partly seeded burst starts its read: \(name)")
            for _ in 0..<200 where model.isLoadingBurst {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.isLoadingBurst, name)
            XCTAssertEqual(model.burstItems.count, 2, "the seed stays visible: \(name)")

            // Download hands the page photo, never the two seeded photos, to the export route.
            XCTAssertTrue(model.canDownloadCurrentSelection, name)
            XCTAssertEqual(model.exportItemsForDownload, [complete[0]], name)

            // The same incomplete answer on the export route is a failed read, not one photo.
            let incompleteAgain = await BurstExportExpansion.expand(
                sourceItems: model.exportItemsForDownload,
                preferredSeriesNameSource: model.baseCurrent,
                burstGroupReader: { _ in answer }
            )
            XCTAssertEqual(incompleteAgain, .burstReadFailed(failedSources: [complete[0]]), name)

            // The export route reads the group again and saves the whole burst once it is known.
            let recovered = await BurstExportExpansion.expand(
                sourceItems: model.exportItemsForDownload,
                preferredSeriesNameSource: model.baseCurrent,
                burstGroupReader: { _ in complete }
            )
            XCTAssertEqual(recovered, .success(items: complete, expandedSingleSeries: true), name)
        }
    }

    @MainActor
    func testViewerOfAPhotoWhoseOnlyOtherMemberIsNoFrameDownloadsThePhoto() async {
        // The photo declares itself and the adjustment data of its edit; the read finds one frame.
        let page = makeItem("main", burstMembers: ["main", "edit-data"])
        let loneFrame = makeItem("main", burstMembers: ["main"])
        let model = PhotoViewerModel(
            items: [page],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(
                    namespace: "burst-lone-frame-\(UUID().uuidString)",
                    rootDirectory: Self.cacheRoot("burst-lone-frame")),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: StaticBurstProvider(items: [loneFrame])
        )
        model.start()
        defer { model.stop() }
        for _ in 0..<200 where model.isLoadingBurst {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isLoadingBurst)
        XCTAssertTrue(model.burstItems.isEmpty, "one frame shows no filmstrip")
        XCTAssertTrue(model.canDownloadCurrentSelection)
        XCTAssertEqual(model.exportItemsForDownload, [page])

        let exported = await BurstExportExpansion.expand(
            sourceItems: model.exportItemsForDownload,
            preferredSeriesNameSource: model.baseCurrent,
            burstGroupReader: { _ in [loneFrame] }
        )
        XCTAssertEqual(exported, .success(items: [page], expandedSingleSeries: false))
    }

    @MainActor
    func testViewerDownloadWaitsWhileTheBurstReadIsInFlight() async {
        let members = ["a", "b", "c"]
        let pages = members.prefix(2).map { makeItem($0, burstMembers: members) }
        let provider = SuspendedBurstProvider()
        let model = PhotoViewerModel(
            items: pages,
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(
                    namespace: "burst-loading-download-\(UUID().uuidString)",
                    rootDirectory: Self.cacheRoot("burst-loading-download")),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: provider
        )
        model.start()
        defer { model.stop() }

        XCTAssertTrue(model.isLoadingBurst)
        XCTAssertEqual(model.burstItems.count, 2, "two of three members are seeded")
        XCTAssertFalse(model.canDownloadCurrentSelection, "a partial filmstrip must not download while it loads")
        XCTAssertEqual(model.exportItemsForDownload, [])
    }

    @MainActor
    func testViewerDownloadStaysAvailableForACompleteFilmstripAndForPlainPhotos() async {
        let root = Self.cacheRoot("burst-download-available")
        let burst = [
            makeItem("a", burstMembers: ["a", "b", "c"]),
            makeItem("b", burstMembers: ["a", "b", "c"]),
            makeItem("c", burstMembers: ["a", "b", "c"]),
        ]
        let complete = PhotoViewerModel(
            items: burst,
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-download-available-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: StaticBurstProvider(items: burst)
        )
        complete.start()
        defer { complete.stop() }
        for _ in 0..<200 where complete.isLoadingBurst {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            complete.canDownloadCurrentSelection,
            "a fully loaded filmstrip and an idle page keep the download available")

        let solo = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "solo"),
            captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/jpeg"
        )
        let plain = PhotoViewerModel(
            items: [solo],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-download-plain-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: EmptyBurstProvider()
        )
        plain.start()
        defer { plain.stop() }
        XCTAssertFalse(plain.isLoadingBurst)
        XCTAssertTrue(plain.canDownloadCurrentSelection, "a photo without a burst stays downloadable")
    }

    private func makeItem(_ id: String, burstMembers: [String]) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Date(timeIntervalSince1970: Double(id.unicodeScalars.first?.value ?? 0)),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: burstMembers
        )
    }

    private static func cacheRoot(_ prefix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

private struct FailingMediaProvider: FullMediaProvider {
    func preview(for uid: PhotoUID) async throws -> Data { throw TestError.unavailable }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw TestError.unavailable
    }
}

private struct EmptyBurstProvider: BurstGroupProvider {
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { [] }
}

private struct StaticBurstProvider: BurstGroupProvider {
    let items: [PhotoItem]
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { items }
}

private struct FailingBurstProvider: BurstGroupProvider {
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { throw TestError.unavailable }
}

/// Never answers until its task is cancelled, so the viewer stays in the loading state.
private struct SuspendedBurstProvider: BurstGroupProvider {
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {
        try await Task.sleep(for: .seconds(3600))
        return []
    }
}

private enum TestError: Error {
    case unavailable
}
