import Foundation
import PhotosCore
import Testing

@testable import AlbumSyncCore

@Suite struct AlbumSyncPlannerTests {
    /// Each link has its own bytes unless the test names a SHA-1.
    private func link(_ id: String, sha1: String? = nil, trashed: Bool = false) -> AlbumSyncRemoteLink {
        AlbumSyncRemoteLink(
            uid: PhotoUID(volumeID: "vol1", nodeID: id), sha1Hex: sha1 ?? "sha-\(id)", isTrashed: trashed)
    }

    @Test func emptyAlbumPlansNothing() {
        let plan = AlbumSyncPlanner.plan(orderedLocalIdentifiers: [], remoteLinks: [:], existingChildLinkIDs: [])
        #expect(plan.toAttach.isEmpty)
        #expect(plan.alreadyMember == 0)
        #expect(plan.missingRemote == 0)
    }

    @Test func allExistingMembersAreNoOps() {
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a", "b"],
            remoteLinks: ["a": link("l1"), "b": link("l2")],
            existingChildLinkIDs: ["l1", "l2"]
        )
        #expect(plan.toAttach.isEmpty)
        #expect(plan.alreadyMember == 2)
    }

    @Test func missingUploadIsReportedNotAttached() {
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a", "b"],
            remoteLinks: ["a": link("l1")],
            existingChildLinkIDs: []
        )
        #expect(plan.toAttach.map(\.uid.nodeID) == ["l1"])
        #expect(plan.missingRemote == 1)
    }

    @Test func trashedRemoteIsNeverAttached() {
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a"],
            remoteLinks: ["a": link("l1", trashed: true)],
            existingChildLinkIDs: []
        )
        #expect(plan.toAttach.isEmpty)
        #expect(plan.trashedRemote == 1)
    }

    @Test func duplicateContentCollapsesToOneAttach() {
        // Two local assets deduped to the same remote link (copied photo): one attach only.
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a", "b"],
            remoteLinks: ["a": link("l1"), "b": link("l1")],
            existingChildLinkIDs: []
        )
        #expect(plan.toAttach.count == 1)
        #expect(plan.duplicatesCollapsed == 1)
    }

    @Test func repeatedSyncIsFullNoOp() {
        let ids = (0..<100).map { "asset-\($0)" }
        let links = Dictionary(uniqueKeysWithValues: ids.map { ($0, link("link-\($0)")) })
        let first = AlbumSyncPlanner.plan(orderedLocalIdentifiers: ids, remoteLinks: links, existingChildLinkIDs: [])
        #expect(first.toAttach.count == 100)
        let second = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ids,
            remoteLinks: links,
            existingChildLinkIDs: Set(first.toAttach.map(\.uid.nodeID))
        )
        #expect(second.toAttach.isEmpty)
        #expect(second.alreadyMember == 100)
    }

    @Test func attachOrderFollowsLocalOrder() {
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["c", "a", "b"],
            remoteLinks: ["a": link("la"), "b": link("lb"), "c": link("lc")],
            existingChildLinkIDs: []
        )
        #expect(plan.toAttach.map(\.uid.nodeID) == ["lc", "la", "lb"])
    }

    @Test func twentyThousandAssetsPlanInLinearTime() {
        let ids = (0..<20_000).map { "asset-\($0)" }
        var links: [String: AlbumSyncRemoteLink] = [:]
        for (i, id) in ids.enumerated() { links[id] = link("link-\(i)") }
        let members = Set((0..<10_000).map { "link-\($0)" })
        let start = ContinuousClock.now
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ids, remoteLinks: links, existingChildLinkIDs: members)
        let elapsed = ContinuousClock.now - start
        #expect(plan.toAttach.count == 10_000)
        #expect(plan.alreadyMember == 10_000)
        // O(n) set planning: generous bound so CI noise can't flake it, but O(n²) would blow it.
        #expect(elapsed < .seconds(2))
    }

    @Test func anotherCopyWithTheSameBytesInTheAlbumCountsAsMember() {
        // Device B's copy of a shared photo: own link, same bytes as device A's member.
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a", "b"],
            remoteLinks: ["a": link("copy-b", sha1: "shared"), "b": link("lb")],
            existingChildLinkIDs: ["copy-a"],
            memberWithSameContent: ["shared": "copy-a"]
        )
        #expect(plan.toAttach.map(\.uid.nodeID) == ["lb"])
        #expect(plan.alreadyMember == 1)
        #expect(plan.duplicatesCollapsed == 0)
    }

    @Test func aDirectMemberAndACopyOfItCountTheMemberOnce() {
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a", "b"],
            remoteLinks: ["a": link("copy-a", sha1: "shared"), "b": link("copy-b", sha1: "shared")],
            existingChildLinkIDs: ["copy-a"],
            memberWithSameContent: ["shared": "copy-a"]
        )
        #expect(plan.toAttach.isEmpty)
        #expect(plan.alreadyMember == 1)
        #expect(plan.duplicatesCollapsed == 1)
    }

    @Test func twoLinksWithTheSameBytesAttachOnce() {
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["b", "a", "c"],
            remoteLinks: ["a": link("la", sha1: "same"), "b": link("lb", sha1: "same"), "c": link("lc")],
            existingChildLinkIDs: []
        )
        #expect(plan.toAttach.map(\.uid.nodeID) == ["lb", "lc"], "the first photo in album order attaches")
        #expect(plan.duplicatesCollapsed == 1)
        #expect(
            plan.sameBytesAlternates.mapValues { $0.map(\.uid.nodeID) } == ["lb": ["la"]],
            "the other link stays ready in case the first one fails")
    }

    @Test func linksWithoutBytesKeepTheirOwnAttach() {
        let noBytes = { (id: String) in
            AlbumSyncRemoteLink(uid: PhotoUID(volumeID: "vol1", nodeID: id), sha1Hex: nil, isTrashed: false)
        }
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a", "b"],
            remoteLinks: ["a": noBytes("la"), "b": noBytes("lb")],
            existingChildLinkIDs: ["member"],
            memberWithSameContent: ["": "member"]
        )
        #expect(plan.toAttach.map(\.uid.nodeID) == ["la", "lb"])
        #expect(plan.alreadyMember == 0)
    }

    @Test func aTrashedCopyIsNeverAMember() {
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: ["a"],
            remoteLinks: ["a": link("copy-b", sha1: "shared", trashed: true)],
            existingChildLinkIDs: ["copy-a"],
            memberWithSameContent: ["shared": "copy-a"]
        )
        #expect(plan.trashedRemote == 1)
        #expect(plan.alreadyMember == 0)
    }
}
