import PhotoViewerCore
import PhotosCore
import XCTest

/// The viewer reads the system's folded layout only from the z-index the overlay arrangement gives its two parts.
/// Measured on the iPhone Duo simulator (iOS 27.1): closed and fully open, the lower part has z-index 1 and the media 0;
/// partly open, the lower part drops to 0 and the two parts lie side by side.
final class ViewerArrangementTests: XCTestCase {
    func testALowerPartAboveTheMediaIsTheWholeDisplay() {
        XCTAssertFalse(ViewerArrangement.isSideBySide(lowerPartZIndex: 1, mediaZIndex: 0))
        XCTAssertEqual(ViewerChromeLayoutProfile.resolve(sideBySide: false, compactLandscape: false), .regular)
        XCTAssertEqual(
            ViewerChromeLayoutProfile.resolve(sideBySide: false, compactLandscape: true), .compactLandscape)
    }

    func testPartsOnOneLevelAreTheFoldedLayout() {
        XCTAssertTrue(ViewerArrangement.isSideBySide(lowerPartZIndex: 0, mediaZIndex: 0))
        // Only the order counts, not the absolute values.
        XCTAssertTrue(ViewerArrangement.isSideBySide(lowerPartZIndex: 2, mediaZIndex: 3))
        XCTAssertFalse(ViewerArrangement.isSideBySide(lowerPartZIndex: 3, mediaZIndex: 2))
        XCTAssertEqual(ViewerChromeLayoutProfile.resolve(sideBySide: true, compactLandscape: false), .folded)
        XCTAssertEqual(ViewerChromeLayoutProfile.resolve(sideBySide: true, compactLandscape: true), .folded)
    }

    /// The owner's values for the folded layout, and the unchanged values of the flat layouts.
    func testTheFoldedLayoutHasATallerFilmstripAndTheDetails() {
        XCTAssertEqual(ViewerChromeLayoutProfile.folded.filmstripItemSide, 60)
        XCTAssertTrue(ViewerChromeLayoutProfile.folded.showsDetails)
        for flat in [ViewerChromeLayoutProfile.regular, .compactLandscape] {
            XCTAssertEqual(flat.filmstripItemSide, 46)
            XCTAssertFalse(flat.showsDetails)
        }
        // The stacked lower part keeps today's filmstrip rows: 8 + 54 + 8 and 6 + 46 + 4.
        XCTAssertEqual(ViewerChromeLayoutProfile.regular.stackedLowerPartHeight, 70)
        XCTAssertEqual(ViewerChromeLayoutProfile.compactLandscape.stackedLowerPartHeight, 56)
    }

    func testOnlyTheFoldedLayoutHasDetailsWithItsValues() throws {
        XCTAssertNil(ViewerChromeLayoutProfile.regular.details)
        XCTAssertNil(ViewerChromeLayoutProfile.compactLandscape.details)
        let details = try XCTUnwrap(ViewerChromeLayoutProfile.folded.details)
        XCTAssertEqual(details.horizontalPadding, 20)
        XCTAssertEqual(details.verticalPadding, 12)
        XCTAssertEqual(details.groupSpacing, 12)
        XCTAssertEqual(details.titleSpacing, 8)
        XCTAssertEqual(details.stackedTitleSpacing, 2)
        XCTAssertEqual(details.albumChipSpacing, 8)
        XCTAssertEqual(details.albumChipHorizontalPadding, 12)
        XCTAssertEqual(details.albumChipVerticalPadding, 6)
        XCTAssertEqual(details.albumChipMaxWidth, 240)
    }

    func testTransportPlacementKeepsFlatDesignAndRequiresChromeAndAnAttachedVideo() {
        for divided in [false, true] {
            XCTAssertEqual(
                ViewerArrangement.videoTransportPlacement(isDivided: divided, showsChrome: true, isAvailable: true),
                divided ? .lowerPart : .media)
            for available in [false, true] {
                XCTAssertEqual(
                    ViewerArrangement.videoTransportPlacement(
                        isDivided: divided, showsChrome: false, isAvailable: available), .hidden)
            }
            XCTAssertEqual(
                ViewerArrangement.videoTransportPlacement(isDivided: divided, showsChrome: true, isAvailable: false),
                .hidden)
        }
    }

    @MainActor func testTransportForwardsCommandsAndRejectsAFormerPagesUpdatesAndCleanup() {
        let transport = ViewerVideoTransport()
        XCTAssertFalse(transport.isAttached(to: nil), "An empty viewer has no transport")
        let firstUID = PhotoUID(volumeID: "transport-volume", nodeID: "first-video")
        let secondUID = PhotoUID(volumeID: "transport-volume", nodeID: "second-video")
        let firstPlayer = NSObject()
        let firstItem = NSObject()
        let secondPlayer = NSObject()
        let secondItem = NSObject()
        let first = VideoPlaybackAttachmentIdentity(generation: 1, player: firstPlayer, item: firstItem)
        let second = VideoPlaybackAttachmentIdentity(generation: 1, player: secondPlayer, item: secondItem)
        var firstToggles = 0
        var secondToggles = 0
        var seeks: [Double] = []
        transport.attach(
            uid: firstUID, attachment: first, snapshot: .init(currentTime: 8, duration: 60),
            onTogglePlayback: { firstToggles += 1 }, onSeekTo: { seeks.append($0) })
        XCTAssertTrue(transport.isAttached(to: firstUID))
        XCTAssertFalse(transport.isAttached(to: secondUID))
        XCTAssertEqual(transport.snapshot.currentTime, 8)
        transport.togglePlayback()
        transport.seek(to: 12)
        XCTAssertEqual(firstToggles, 1)
        XCTAssertEqual(seeks, [12])
        let current = ViewerVideoTransport.Snapshot(currentTime: 20, duration: 90, isPlaying: true)
        transport.attach(
            uid: secondUID, attachment: second, snapshot: current,
            onTogglePlayback: { secondToggles += 1 }, onSeekTo: { seeks.append($0) })
        transport.update(.init(currentTime: 99), attachment: first)
        XCTAssertEqual(transport.snapshot, current, "A former page cannot publish over the current page")
        transport.detach(attachment: first)
        XCTAssertTrue(transport.isAttached(to: secondUID), "A former page cannot detach the current page")
        XCTAssertFalse(transport.isAttached(to: firstUID))
        transport.togglePlayback()
        XCTAssertEqual(secondToggles, 1)
        XCTAssertEqual(firstToggles, 1)
        let updated = ViewerVideoTransport.Snapshot(currentTime: 24, duration: 90, isLoading: true)
        transport.update(updated, attachment: second)
        XCTAssertEqual(transport.snapshot, updated)
        transport.detach(attachment: second)
        XCTAssertNil(transport.uid)
        XCTAssertEqual(transport.snapshot, .init())
        transport.togglePlayback()
        transport.seek(to: 30)
        XCTAssertEqual(secondToggles, 1, "Detach removes commands to the old owner")
        XCTAssertEqual(seeks, [12])
    }
}
