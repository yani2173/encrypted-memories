import PhotosCore
import Testing
import UIKit

@testable import TimelineUIKitFeature

@MainActor
@Suite("UIKit grid host missing tiles")
struct UIKitTimelineMissingTilesTests {
    private func uid(_ name: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: name) }

    private func makeHost(_ tiles: [PhotoUID]) -> UIKitTimelineGridHostView {
        let host = UIKitTimelineGridHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.itemIndexByUID = Dictionary(uniqueKeysWithValues: tiles.enumerated().map { ($1, $0) })
        return host
    }

    @Test func missingTilesKeepOnlyTheNonResidentOnesNewestFirst() {
        let tiles = ["a", "b", "c", "d"].map(uid)
        let host = makeHost(tiles)

        let missing = host.missingRetryableTiles(in: tiles, isResident: { $0 == tiles[1] })

        #expect(missing.uids == [tiles[3], tiles[2], tiles[0]])
    }

    @Test func theOrderFollowsTheLibraryIndexNotTheGivenOrder() {
        let tiles = ["a", "b", "c"].map(uid)
        let host = makeHost(tiles)

        let missing = host.missingRetryableTiles(in: [tiles[1], tiles[2], tiles[0]], isResident: { _ in false })

        #expect(missing.uids == [tiles[2], tiles[1], tiles[0]])
    }

    @Test func noMissingTileLeavesAnEmptyResult() {
        let tiles = ["a", "b"].map(uid)
        let host = makeHost(tiles)

        let missing = host.missingRetryableTiles(in: tiles, isResident: { _ in true })

        #expect(missing.uids.isEmpty)
        #expect(missing.ramReady == 0)
    }
}
