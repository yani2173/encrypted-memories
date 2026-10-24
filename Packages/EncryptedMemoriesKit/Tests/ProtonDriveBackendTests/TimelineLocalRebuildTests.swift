import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Timeline rebuild from the local store")
struct TimelineLocalRebuildTests {
    private static let cursor = "event-7"
    private static let persistedToken = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: cursor)

    private static func conditions(
        basis: TimelineLoadBasis? = TimelineLoadBasis(
            eventToken: cursor, revisions: TimelineLocalRevisions(mediaType: 1, order: 1)),
        eventToken: String = cursor,
        revisions: TimelineLocalRevisions = TimelineLocalRevisions(mediaType: 2, order: 1),
        pendingUploads: Bool = false,
        unmaterializedEvidence: Bool = false,
        awaitingLibrary: Bool = false,
        restored: Bool = false,
        continuityRecovery: Bool = false
    ) -> TimelineLocalRebuild.Conditions {
        TimelineLocalRebuild.Conditions(
            basis: basis, currentEventToken: eventToken, currentRevisions: revisions,
            hasPendingLocalUploads: pendingUploads, hasUnmaterializedLocalEvidence: unmaterializedEvidence,
            hasPhotosAwaitingLibrary: awaitingLibrary, hasRestoredPhotos: restored,
            continuityRecoveryRequired: continuityRecovery)
    }

    private static func item(
        _ node: String, at time: Double = 100, type: String = "image/jpeg", tags: Set<PhotoTag> = [],
        live: Bool = false, related: String? = nil, burst: [String] = [], duration: Double? = nil
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: node), captureTime: Date(timeIntervalSince1970: time),
            mediaType: type, isLivePhoto: live, relatedVideoID: related, durationSeconds: duration, tags: tags,
            burstMemberIDs: burst)
    }

    /// Counts the store reads that a plan makes.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens = 0
        private var rules = 0
        private var items = 0
        private var evidence = 0
        var tokenReads: Int { lock.withLock { tokens } }
        var ruleReads: Int { lock.withLock { rules } }
        var itemReads: Int { lock.withLock { items } }
        var evidenceReads: Int { lock.withLock { evidence } }
        func token() { lock.withLock { tokens += 1 } }
        func rule() { lock.withLock { rules += 1 } }
        func item() { lock.withLock { items += 1 } }
        func evidenceRead() { lock.withLock { evidence += 1 } }
        var total: Int { tokenReads + ruleReads + itemReads + evidenceReads }
    }

    private static func plan(
        _ conditions: TimelineLocalRebuild.Conditions,
        storedToken: String? = persistedToken,
        motionRuleIsCurrent: Bool = true,
        stored: [PhotoItem]? = [item("a")],
        evidence: [String: String] = [:],
        reads: Reads = Reads()
    ) -> [TimelineSection]? {
        TimelineLocalRebuild.plan(
            conditions,
            storedValidationToken: {
                reads.token()
                return storedToken
            },
            motionRuleIsCurrent: {
                reads.rule()
                return motionRuleIsCurrent
            },
            storedItems: {
                reads.item()
                return stored
            },
            mediaTypeEvidence: {
                reads.evidenceRead()
                return evidence
            })
    }

    @Test func aRevisionOnlyChangeForTheSameCursorRebuildsFromTheStore() {
        let sections = Self.plan(Self.conditions(), stored: [Self.item("a"), Self.item("b", at: 200)])
        #expect(sections?.first?.items.map(\.uid.nodeID) == ["a", "b"])
        // The order revision alone counts as well.
        #expect(
            Self.plan(Self.conditions(revisions: TimelineLocalRevisions(mediaType: 1, order: 2))) != nil)
    }

    @Test func everyOtherSituationKeepsTheListing() {
        let ineligible: [(String, TimelineLocalRebuild.Conditions)] = [
            ("no earlier load of this backend", Self.conditions(basis: nil)),
            (
                "the server cursor moved",
                Self.conditions(
                    basis: TimelineLoadBasis(
                        eventToken: "event-6", revisions: TimelineLocalRevisions(mediaType: 1, order: 1)))
            ),
            (
                "nothing changed, a plain refresh",
                Self.conditions(revisions: TimelineLocalRevisions(mediaType: 1, order: 1))
            ),
            ("an upload waits for the listing", Self.conditions(pendingUploads: true)),
            ("evidence of an upload waits for the listing", Self.conditions(unmaterializedEvidence: true)),
            ("a trashed photo waits for the listing", Self.conditions(awaitingLibrary: true)),
            ("a restored photo waits to be listed", Self.conditions(restored: true)),
            ("the event history was reset", Self.conditions(continuityRecovery: true)),
        ]
        for (reason, conditions) in ineligible {
            let reads = Reads()
            #expect(Self.plan(conditions, reads: reads) == nil, "\(reason)")
            // The conditions come first: nothing of the store is read when they say no, not even its token.
            #expect(reads.total == 0, "\(reason)")
        }
    }

    @Test func aStoredInventoryOfAnotherCursorIsNotUsed() {
        let other = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-6")
        for token in [other, nil, Self.cursor] {
            let reads = Reads()
            #expect(Self.plan(Self.conditions(), storedToken: token, reads: reads) == nil)
            // Only the token is read; the rule mark and the items wait for it.
            #expect(reads.tokenReads == 1 && reads.ruleReads == 0 && reads.itemReads == 0)
        }
    }

    @Test func aLivePhotoWithAnUnreadMotionKeepsTheListing() {
        // The Live control shows, but no video is named: a listing reads the related types again for it.
        let unread = [Self.item("a"), Self.item("live", live: true, related: nil)]
        let reads = Reads()
        #expect(Self.plan(Self.conditions(), stored: unread, reads: reads) == nil)
        #expect(reads.itemReads == 1 && reads.evidenceReads == 0)
        #expect(TimelineLocalRebuild.hasUnreadLiveMotion(unread))
        // A read motion, a photo that is no Live Photo and a Live Photo without a video do not hold it back.
        let settled = [
            Self.item("a"), Self.item("live", live: true, related: "motion"), Self.item("edit", live: false),
        ]
        #expect(!TimelineLocalRebuild.hasUnreadLiveMotion(settled))
        #expect(Self.plan(Self.conditions(), stored: settled) != nil)
    }

    @Test func aStoredCopyThatTheCurrentMotionRuleDidNotChooseKeepsTheListing() {
        let reads = Reads()
        #expect(Self.plan(Self.conditions(), motionRuleIsCurrent: false, reads: reads) == nil)
        #expect(reads.ruleReads == 1 && reads.itemReads == 0)
    }

    @Test func theBasisIsTheRawCursorOfASavedLoadAndOfNothingElse() throws {
        let revisions = TimelineLocalRevisions(mediaType: 1, order: 1)
        let commit = TimelineLoadCommitPolicy.decide(
            startEventToken: Self.cursor, endEventToken: Self.cursor, enrichmentComplete: true)
        let basis = try #require(
            TimelineLocalRebuild.basis(
                persistedValidationToken: commit.persistedValidationToken, eventToken: commit.monitorBaseline,
                revisions: revisions, saved: true))
        // The raw cursor, not the prefixed token that is stored beside the inventory: the save adds the prefix.
        #expect(basis.eventToken == Self.cursor)
        #expect(commit.persistedValidationToken == Self.cursor)
        #expect(
            TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: basis.eventToken)
                == Self.persistedToken)
        let later = TimelineLocalRevisions(mediaType: 2, order: 1)
        #expect(Self.plan(Self.conditions(basis: basis, revisions: later)) != nil)
        // A basis made from the prefixed token never matches the raw cursor of the next load.
        let prefixed = TimelineLoadBasis(eventToken: Self.persistedToken, revisions: revisions)
        #expect(Self.plan(Self.conditions(basis: prefixed, revisions: later)) == nil)

        // No save, no basis: a failed save or an incomplete enrichment leaves the next load to list.
        #expect(
            TimelineLocalRebuild.basis(
                persistedValidationToken: commit.persistedValidationToken, eventToken: commit.monitorBaseline,
                revisions: revisions, saved: false) == nil)
        let incomplete = TimelineLoadCommitPolicy.decide(
            startEventToken: Self.cursor, endEventToken: Self.cursor, enrichmentComplete: false)
        #expect(incomplete.persistedValidationToken == nil)
        #expect(
            TimelineLocalRebuild.basis(
                persistedValidationToken: incomplete.persistedValidationToken, eventToken: incomplete.monitorBaseline,
                revisions: revisions, saved: true) == nil)
    }

    @Test func aRebuildHasItsOwnLabelInTheSupportReport() {
        #expect(LibrarySyncSupportSnapshot.SourcePath.localStore.rawValue == "localStore")
        #expect(LibrarySyncSupportSnapshot.SourcePath.localStore != .cache)
    }

    @Test func aFailedOrEmptyStoreReadKeepsTheListing() {
        #expect(Self.plan(Self.conditions(), stored: nil) == nil)
        #expect(Self.plan(Self.conditions(), stored: []) == nil)
        let throwing = TimelineLocalRebuild.plan(
            Self.conditions(), storedValidationToken: { Self.persistedToken }, motionRuleIsCurrent: { true },
            storedItems: { throw CocoaError(.fileReadCorruptFile) }, mediaTypeEvidence: { [:] })
        #expect(throwing == nil)
    }

    @Test func theEvidenceIsAppliedLikeAListingDoes() {
        let stored = [
            Self.item("photo-to-video", at: 10, type: "image/jpeg"),
            Self.item("video-to-photo", at: 20, type: "video/quicktime", tags: [.videos, .favorites]),
            Self.item("untouched", at: 30, type: "image/heic", tags: [.favorites]),
        ]
        let items = TimelineLocalRebuild.sections(
            from: stored,
            mediaTypeEvidence: ["photo-to-video": "video/mp4", "video-to-photo": "image/jpeg", "other": "video/mp4"]
        ).flatMap(\.items)
        let byNode = Dictionary(uniqueKeysWithValues: items.map { ($0.uid.nodeID, $0) })
        #expect(byNode["photo-to-video"]?.mediaType == "video/mp4")
        #expect(byNode["photo-to-video"]?.tags == [.videos])
        #expect(byNode["video-to-photo"]?.mediaType == "image/jpeg")
        #expect(byNode["video-to-photo"]?.tags == [.favorites])
        #expect(byNode["untouched"]?.mediaType == "image/heic")
        #expect(byNode["untouched"]?.tags == [.favorites])
    }

    @Test func everythingElseOfAStoredItemSurvivesAndTheShapeMatchesAListing() throws {
        let stored = [
            Self.item("live", at: 300, live: true, related: "motion", duration: 4),
            Self.item("burst", at: 100, burst: ["burst", "burst-2"]),
            Self.item("tie-b", at: 200),
            Self.item("tie-a", at: 200),
        ]
        let sections = TimelineLocalRebuild.sections(from: stored, mediaTypeEvidence: [:])
        let section = try #require(sections.first)
        #expect(sections.count == 1 && section.id == "all" && section.title == "")
        // Canonical timeline order: time, then volume and node.
        #expect(section.items.map(\.uid.nodeID) == ["burst", "tie-a", "tie-b", "live"])
        #expect(section.date == section.items.first?.captureTime)
        let live = try #require(section.items.first { $0.uid.nodeID == "live" })
        #expect(live.isLivePhoto && live.relatedVideoID == "motion")
        #expect(section.items.first { $0.uid.nodeID == "burst" }?.burstMemberIDs == ["burst", "burst-2"])
        // A listing enumerates no duration; a save keeps the one that was learned later.
        #expect(live.durationSeconds == nil)
        #expect(TimelineLocalRebuild.sections(from: [], mediaTypeEvidence: [:]).first?.items.isEmpty == true)
    }

    @Test func aPublishedEvidenceRevisionReachesTheSectionsOfARealStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        let items = [Self.item("a", at: 1), Self.item("b", at: 2), Self.item("c", at: 3)]
        #expect(store.save(items, validationToken: Self.persistedToken).succeeded)
        let before = TimelineLocalRevisions(mediaType: store.mediaTypeEvidenceRevision(), order: 0)
        let basis = TimelineLoadBasis(eventToken: Self.cursor, revisions: before)

        // A background reconciliation learns that "b" is a video and publishes one revision at its end.
        store.recordMediaTypeEvidence(
            [PhotoUID(volumeID: "vol", nodeID: "b"): "video/quicktime"], publishRevision: false)
        #expect(store.publishMediaTypeEvidenceRevision())
        let after = TimelineLocalRevisions(mediaType: store.mediaTypeEvidenceRevision(), order: 0)
        #expect(after != before)

        let conditions = Self.conditions(basis: basis, revisions: after)
        let sections = TimelineLocalRebuild.plan(
            conditions,
            storedValidationToken: { store.validationToken() },
            motionRuleIsCurrent: { true },
            storedItems: { try store.cachedTimelineSnapshot()?.sections.flatMap(\.items) },
            mediaTypeEvidence: { store.mediaTypeEvidenceForDisplay(volumeID: "vol").types })
        let rebuilt = try #require(sections?.first?.items)
        #expect(rebuilt.map(\.uid.nodeID) == ["a", "b", "c"])
        #expect(rebuilt.map(\.isVideo) == [false, true, false])
        #expect(rebuilt[1].tags.contains(.videos))

        // The rule mark of the motion choice: set after a marked save, void after any later changed save.
        #expect(!store.relatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.relatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.relatedVideosChosen(by: "another.rule") == false)

        // Once this rebuild is the basis, the same revisions are a plain refresh again.
        let next = TimelineLoadBasis(eventToken: Self.cursor, revisions: after)
        #expect(
            !TimelineLocalRebuild.isEligible(
                Self.conditions(basis: next, revisions: after), storedValidationToken: store.validationToken()))
        // A save for another cursor makes the stored inventory unusable.
        #expect(store.save(items, validationToken: "photos-inventory-v2:event-8").succeeded)
        #expect(!TimelineLocalRebuild.isEligible(conditions, storedValidationToken: store.validationToken()))
        // A changed save without a new mark voids the mark, so the next load reads the types again.
        #expect(store.save(items + [Self.item("d", at: 4)], validationToken: Self.persistedToken).succeeded)
        #expect(!store.relatedVideosChosen(by: LivePhotoMotionLinks.rule))
    }

    @Test func theSourcePolicyChoosesTheStoreOnlyWhereTheSDKCacheWasChosen() {
        func source(
            cached: String?, current: String = "photos-inventory-v2:event-7", pending: Bool = false,
            unmaterialized: Bool = false, local: Bool
        ) -> TimelineInventorySource {
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: cached, currentEventToken: current, hasPendingLocalUploads: pending,
                hasUnmaterializedLocalEvidence: unmaterialized, canRebuildLocally: local)
        }
        let same = "photos-inventory-v2:event-7"
        #expect(source(cached: same, local: true) == .localStore)
        #expect(source(cached: same, local: false) == .sdkCache)
        // Whatever sent the load to a listing before still does.
        #expect(source(cached: "photos-inventory-v2:event-6", local: true) == .authoritativePhotosList)
        #expect(source(cached: nil, local: true) == .authoritativePhotosList)
        #expect(source(cached: same, pending: true, local: true) == .authoritativePhotosList)
        #expect(source(cached: same, unmaterialized: true, local: true) == .authoritativePhotosList)
    }
}
