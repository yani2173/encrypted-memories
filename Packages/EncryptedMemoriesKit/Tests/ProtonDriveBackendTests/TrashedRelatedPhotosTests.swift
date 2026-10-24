import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

/// Restoring a series that version 1.1.0 dissolved: it moved the main photo and every frame to the trash in one request.
@Suite("Related photos trashed with their main photo")
struct TrashedRelatedPhotosTests {
    private static func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "volume", nodeID: id) }
    private let main = Self.uid("main")
    private let mainTrash: Int64 = 1_790_000_000

    private func trashed(at time: Int64?, main mainID: String? = "main") -> RemoteLinkVisibility {
        RemoteLinkVisibility(isActive: false, mainPhotoLinkID: mainID, trashTime: time)
    }

    private func decide(_ frames: [String: RemoteLinkVisibility], mainLink: RemoteLinkVisibility? = nil) -> [String] {
        var links = frames
        links["main"] = mainLink ?? trashed(at: mainTrash, main: nil)
        let candidates = [main: frames.keys.sorted().map(Self.uid)]
        return TrashedRelatedPhotos.restoredWith([main], candidates: candidates, links: links).map(\.nodeID)
    }

    // MARK: Decision

    @Test func framesTrashedWithTheMainPhotoComeBackWithIt() {
        #expect(decide(["f1": trashed(at: mainTrash), "f2": trashed(at: mainTrash + 3)]) == ["f1", "f2"])
    }

    @Test func aFrameTrashedADayLaterStaysInTheTrash() {
        #expect(decide(["f1": trashed(at: mainTrash), "late": trashed(at: mainTrash + 86_400)]) == ["f1"])
    }

    @Test func aFrameWithoutATrashTimeStaysInTheTrash() {
        #expect(decide(["f1": trashed(at: nil)]) == [])
    }

    @Test func aMainPhotoWithoutATrashTimeBringsNoFrame() {
        #expect(decide(["f1": trashed(at: mainTrash)], mainLink: trashed(at: nil, main: nil)) == [])
    }

    @Test func aMainPhotoThatIsBackInTheLibraryBringsNoFrame() {
        // The main photo was restored elsewhere; its link can still carry the time of the trash.
        let restored = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: nil, trashTime: mainTrash)
        #expect(decide(["f1": trashed(at: mainTrash)], mainLink: restored) == [])
    }

    @Test func aFrameInTheLibraryIsNoRestoreTarget() {
        // A link in the library can carry the time of an earlier trash.
        let active = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: "main", trashTime: mainTrash)
        #expect(decide(["f1": active]) == [])
    }

    @Test func aFrameOfAnotherMainPhotoStaysInTheTrash() {
        #expect(decide(["f1": trashed(at: mainTrash, main: "other")]) == [])
    }

    @Test func aFrameThatTheServerNoLongerKnowsIsSkipped() {
        let links = ["main": trashed(at: mainTrash, main: nil)]
        let restored = TrashedRelatedPhotos.restoredWith([main], candidates: [main: [Self.uid("gone")]], links: links)
        #expect(restored == [])
    }

    @Test func aFrameComesBackWithinFiveMinutesOfItsMainPhotoAndNotLater() {
        #expect(
            decide(["fourMinutes": trashed(at: mainTrash + 240), "sixMinutes": trashed(at: mainTrash + 360)]) == [
                "fourMinutes"
            ])
    }

    @Test func theWindowHoldsOnBothSidesOfTheMainPhotosTrashTime() {
        let window = TrashedRelatedPhotos.trashedTogetherWindow
        let frames = [
            "before": trashed(at: mainTrash - window), "after": trashed(at: mainTrash + window),
            "tooEarly": trashed(at: mainTrash - window - 1), "tooLate": trashed(at: mainTrash + window + 1),
        ]
        #expect(decide(frames) == ["after", "before"])
    }

    @Test func trashTimesAtTheEndsOfTheRangeNeverTrap() {
        let maximum = trashed(at: .max, main: nil)
        let minimum = trashed(at: .min, main: nil)
        #expect(decide(["f1": trashed(at: .min)], mainLink: maximum) == [], "the distance does not fit into Int64")
        #expect(decide(["f1": trashed(at: .max)], mainLink: minimum) == [])
        #expect(decide(["f1": trashed(at: .max)], mainLink: maximum) == ["f1"])
        #expect(decide(["f1": trashed(at: .min)], mainLink: minimum) == ["f1"])
    }

    @Test func eachFrameComesBackOnlyWithItsOwnMainPhoto() {
        let other = Self.uid("main2")
        let links = [
            "main": trashed(at: mainTrash, main: nil), "main2": trashed(at: mainTrash + 2, main: nil),
            "f1": trashed(at: mainTrash + 1), "g1": trashed(at: mainTrash + 1, main: "main2"),
        ]
        // A stale listing can list a frame under the wrong main photo; the server's answer decides.
        let candidates = [main: [Self.uid("f1"), Self.uid("g1")], other: [Self.uid("g1"), Self.uid("f1")]]

        #expect(TrashedRelatedPhotos.restoredWith([main], candidates: candidates, links: links).map(\.nodeID) == ["f1"])
        #expect(
            TrashedRelatedPhotos.restoredWith([other], candidates: candidates, links: links).map(\.nodeID) == ["g1"])
        #expect(
            TrashedRelatedPhotos.restoredWith([main, other], candidates: candidates, links: links).map(\.nodeID)
                == ["f1", "g1"])
    }

    // MARK: Restore order and failures

    @Test func theRestoreReadsTheTrashTimesFirstAndThenBringsTheSeriesBack() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000, "f2": 1002, "late": 90_000])

        let frames = try await server.restore([main], candidates: [main: ["f1", "f2", "late"].map(Self.uid)])

        #expect(frames.map(\.nodeID) == ["f1", "f2"])
        #expect(await server.calls == [.read(4), .restore(["main"]), .restore(["f1", "f2"])])
        #expect(await server.inTrash == ["late"], "the frame deleted at another time stays in the trash")
    }

    @Test func aMainPhotoWithoutTrashedRelatedPhotosCostsNoRead() async throws {
        let server = TrashServer(trashTimes: ["main": 1000])

        let frames = try await server.restore([main], candidates: [:])

        #expect(frames.isEmpty)
        #expect(await server.calls == [.restore(["main"])])
    }

    @Test func aFailedReadRestoresTheMainPhotoAlone() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000], failingRead: true)

        let frames = try await server.restore([main], candidates: [main: [Self.uid("f1")]])

        #expect(frames.isEmpty)
        #expect(await server.inTrash == ["f1"])
    }

    @Test func aCancelDuringTheReadRestoresNothing() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000], cancelsDuringRead: true)

        await #expect(throws: CancellationError.self) {
            try await server.restore([main], candidates: [main: [Self.uid("f1")]])
        }
        #expect(await server.inTrash == ["f1", "main"])
    }

    @Test func aFailedFrameRestoreKeepsTheMainPhotoRestored() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000], failingRestores: ["f1"])

        let frames = try await server.restore([main], candidates: [main: [Self.uid("f1")]])

        #expect(frames.isEmpty)
        #expect(await server.inTrash == ["f1"])
    }

    @Test func aRefusedFrameStaysWhileTheOtherFramesComeBack() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000, "f2": 1001], failingRestores: ["f2"])

        let frames = try await server.restore([main], candidates: [main: [Self.uid("f1"), Self.uid("f2")]])

        #expect(frames.isEmpty, "the batch reports a failure, so no frame counts as restored")
        #expect(await server.inTrash == ["f2"], "Proton applies the other links of the batch")
    }

    @Test func theFramesOfTheMainPhotosThatCameBackFollowWhenProtonRefusesAnother() async throws {
        let other = Self.uid("main2")
        let server = TrashServer(
            trashTimes: ["main": 1000, "f1": 1000, "main2": 1000, "g1": 1001], relatedTo: ["g1": "main2"],
            failingRestores: ["main2"])

        await #expect(throws: DriveBatchActionError.self) {
            try await server.restore([main, other], candidates: [main: [Self.uid("f1")], other: [Self.uid("g1")]])
        }
        #expect(await server.inTrash == ["g1", "main2"], "the refused main photo keeps its frame in the trash")
    }

    @Test func aRestoreThatProtonAppliedBeforeItsAnswerFailedStillBringsTheFramesBack() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000], failsAfterApplying: ["main"])

        await #expect(throws: URLError.self) {
            try await server.restore([main], candidates: [main: [Self.uid("f1")]])
        }
        #expect(await server.inTrash == [], "the series is back as a whole")
        #expect(await server.calls == [.read(2), .restore(["main"]), .reread(1), .restore(["f1"])])
    }

    @Test func aCancelDuringTheMainRestoreRestoresNoFrame() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000], cancelsAfterApplying: ["main"])

        await #expect(throws: CancellationError.self) {
            try await server.restore([main], candidates: [main: [Self.uid("f1")]])
        }
        #expect(await server.inTrash == ["f1"])
        #expect(await server.calls == [.read(2), .restore(["main"])], "no read and no frame restore after a cancel")
    }

    @Test func aCancelledTaskWhoseRestoreEndsWithANetworkErrorRestoresNoFrame() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000], cancelsTaskAfterApplying: ["main"])

        await #expect(throws: URLError.self) {
            try await server.restore([main], candidates: [main: [Self.uid("f1")]])
        }
        #expect(await server.calls == [.read(2), .restore(["main"])], "no read and no frame restore after a cancel")
    }

    @Test func theReadAfterAPartialRestoreMayWaitForARateLimit() async throws {
        let server = TrashServer(
            trashTimes: ["main": 1000, "f1": 1000, "main2": 1000], failingRestores: ["main2"],
            rateLimitedAfterFirstRead: true)

        await #expect(throws: DriveBatchActionError.self) {
            try await server.restore([main, Self.uid("main2")], candidates: [main: [Self.uid("f1")]])
        }
        #expect(await server.inTrash == ["main2"], "the frame of the restored main photo came back")
    }

    @Test func aFailedReadAfterAPartialRestoreLeavesTheFramesAndKeepsTheError() async throws {
        let server = TrashServer(
            trashTimes: ["main": 1000, "f1": 1000, "main2": 1000], failingRestores: ["main2"], failingReread: true)

        await #expect(throws: DriveBatchActionError.self) {
            try await server.restore([main, Self.uid("main2")], candidates: [main: [Self.uid("f1")]])
        }
        #expect(await server.inTrash == ["f1", "main2"])
    }

    @Test func aFailedMainRestoreBringsNoFrameBack() async throws {
        let server = TrashServer(trashTimes: ["main": 1000, "f1": 1000], failingRestores: ["main"])

        await #expect(throws: DriveBatchActionError.self) {
            try await server.restore([main], candidates: [main: [Self.uid("f1")]])
        }
        #expect(await server.inTrash == ["f1", "main"])
    }

    // MARK: Listing

    @Test func theTrashListingHidesRelatedPhotosAndKeepsThemForTheRestore() throws {
        let links = try JSONDecoder().decode(
            [TrashLink].self,
            from: Data(
                #"""
                [{"LinkID":"main","Type":2,"FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":null}}}},
                 {"LinkID":"f1","Type":2,"FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"main"}}}},
                 {"LinkID":"f2","Type":2,"FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"main"}}}},
                 {"LinkID":"single","Type":2}]
                """#.utf8))

        let (shown, related) = TrashedRelatedPhotos.split(links, volumeID: "volume")

        #expect(shown.compactMap(\.linkID) == ["main", "single"])
        #expect(related == [main: [Self.uid("f1"), Self.uid("f2")]])
    }

    @Test func theRelatedPhotosOfARestoredMainPhotoLeaveTheListing() {
        var listing = RecentlyDeletedIdentities(listing: nil)
        let other = Self.uid("other")
        let related = [main: [Self.uid("f1")], other: [Self.uid("o1")]]
        listing.listedRelatedPhotos(related)
        let stored = listing.persisted

        #expect(listing.trashedRelatedPhotos(of: [main]) == [main: [Self.uid("f1")]])
        #expect(stored == RecentlyDeletedIdentities(listing: nil).persisted, "the related photos are never stored")

        listing.restored([main])
        #expect(listing.trashedRelatedPhotos(of: [main, other]) == [other: [Self.uid("o1")]])

        listing.emptied()
        #expect(listing.trashedRelatedPhotos(of: [other]).isEmpty)
    }
}

/// Proton's trash for the restore seam: trash times by link, and the restore that brings links back to the library.
private actor TrashServer {
    struct Failure: Error {}
    enum Call: Equatable {
        case read(Int)
        case reread(Int)
        case restore([String])
    }

    private var trashTimes: [String: Int64]
    private let failingRead: Bool
    private let cancelsDuringRead: Bool
    private let failingRestores: Set<String>
    private let relatedTo: [String: String]
    private let failsAfterApplying: Set<String>
    private let cancelsAfterApplying: Set<String>
    private let cancelsTaskAfterApplying: Set<String>
    private let rateLimitedAfterFirstRead: Bool
    private let failingReread: Bool
    private var reads = 0
    private(set) var calls: [Call] = []
    var inTrash: [String] { trashTimes.keys.sorted() }

    init(
        trashTimes: [String: Int64], relatedTo: [String: String] = [:], failingRead: Bool = false,
        cancelsDuringRead: Bool = false, failingRestores: Set<String> = [], failsAfterApplying: Set<String> = [],
        cancelsAfterApplying: Set<String> = [], cancelsTaskAfterApplying: Set<String> = [],
        rateLimitedAfterFirstRead: Bool = false, failingReread: Bool = false
    ) {
        self.cancelsTaskAfterApplying = cancelsTaskAfterApplying
        self.failsAfterApplying = failsAfterApplying
        self.cancelsAfterApplying = cancelsAfterApplying
        self.rateLimitedAfterFirstRead = rateLimitedAfterFirstRead
        self.failingReread = failingReread
        self.trashTimes = trashTimes
        self.relatedTo = relatedTo
        self.failingRead = failingRead
        self.cancelsDuringRead = cancelsDuringRead
        self.failingRestores = failingRestores
    }

    func restore(_ mains: [PhotoUID], candidates: [PhotoUID: [PhotoUID]]) async throws -> [PhotoUID] {
        try await TrashedRelatedPhotos.restore(
            mains, candidates: candidates, readLinks: { try self.read($0) }, rereadLinks: { try self.reread($0) },
            restore: { try self.restoreLinks($0) })
    }

    private func read(_ ids: [String]) throws -> [String: RemoteLinkVisibility] {
        calls.append(.read(ids.count))
        reads += 1
        if failingRead || (rateLimitedAfterFirstRead && reads > 1) { throw Failure() }
        if cancelsDuringRead {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        return state(of: ids)
    }

    /// The read that may wait for a rate limit.
    private func reread(_ ids: [String]) throws -> [String: RemoteLinkVisibility] {
        calls.append(.reread(ids.count))
        if failingReread { throw Failure() }
        return state(of: ids)
    }

    private func state(of ids: [String]) -> [String: RemoteLinkVisibility] {
        var links: [String: RemoteLinkVisibility] = [:]
        for id in ids {
            links[id] = RemoteLinkVisibility(
                isActive: trashTimes[id] == nil,
                mainPhotoLinkID: relatedTo[id] ?? (id.hasPrefix("main") ? nil : "main"), trashTime: trashTimes[id])
        }
        return links
    }

    private func restoreLinks(_ uids: [PhotoUID]) throws {
        let ids = uids.map(\.nodeID)
        calls.append(.restore(ids))
        // Proton answers per link: it restores every link that it accepts, and the restore ends its trash time.
        let refused = ids.filter(failingRestores.contains)
        for id in ids where !refused.contains(id) { trashTimes[id] = nil }
        if !refused.isEmpty {
            throw DriveBatchActionError(failed: refused.count, retryableLinkIDs: [], total: ids.count)
        }
        // A single request keeps its own error, even when Proton applied it.
        if !failsAfterApplying.isDisjoint(with: ids) { throw URLError(.timedOut) }
        if !cancelsAfterApplying.isDisjoint(with: ids) { throw CancellationError() }
        // The URL loading system reports a cancelled task as a network error.
        if !cancelsTaskAfterApplying.isDisjoint(with: ids) {
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.cancelled)
        }
    }
}
