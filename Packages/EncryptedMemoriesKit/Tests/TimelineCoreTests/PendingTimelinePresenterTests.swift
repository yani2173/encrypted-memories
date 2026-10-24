import Foundation
import GridCore
import PhotosCore
import Testing

@testable import TimelineCore
@testable import UploadCore

@Suite @MainActor struct PendingTimelinePresenterTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func remote(_ node: String, second: TimeInterval) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: node), captureTime: base.addingTimeInterval(second),
            mediaType: "image/jpeg")
    }

    private func tile(
        _ id: String,
        second: TimeInterval,
        handoff: PhotoUID? = nil,
        settled: Bool = false,
        badge: PendingUploadBadge = .waiting,
        replaces: [PhotoUID] = []
    ) -> PendingTile {
        let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
        return PendingTile(
            key: key,
            item: PhotoItem(uid: key.localUID, captureTime: base.addingTimeInterval(second), mediaType: "image/heic"),
            revision: UploadBackupRevision(rawValue: 1),
            handoff: handoff,
            isSettled: settled,
            badge: badge,
            displayName: id,
            replaces: replaces
        )
    }

    private func pending(
        _ tiles: [PendingTile], membership: UInt64, progress: [PhotoUID: Int] = [:]
    )
        -> PendingBackupSnapshot
    {
        PendingBackupSnapshot(membershipRevision: membership, progressRevision: 0, tiles: tiles, progress: progress)
    }

    private func settle(_ presenter: PendingTimelinePresenter) async -> PendingTimelinePresentation {
        await presenter.waitUntilIdle()
        return presenter.current
    }

    @Test(arguments: [false, true])
    func remoteEditBeforePendingMetadataNeverShowsBothPhotos(stalePending: Bool) async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter(replacementLookup: { [ledger = harness.recorder.replacementLedger] in
            ledger.replacementHandoffs()
        })
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        var presentations: [PendingTimelinePresentation] = []
        presenter.onChange = { presentations.append($0) }
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        _ = await settle(presenter)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 1), replaces: [earlier.uid])
        if stalePending {
            presenter.setPending(
                pending([tile("p", second: 10, replaces: [earlier.uid])], membership: 1), enabled: true)
            _ = await settle(presenter)
        }
        harness.handoff(revision: 1, remote: uploaded.uid)
        // No coordinator snapshot or metadata fetch has delivered this handoff.
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == (stalePending ? [uploaded.uid] : [earlier.uid]))
        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: uploaded.uid, settled: true, replaces: [earlier.uid])], membership: 2),
            enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])
        #expect(!presentations.isEmpty)
        for presentation in presentations {
            let uids = Set(presentation.items.map(\.uid))
            #expect(
                !uids.contains(earlier.uid) || (!uids.contains(uploaded.uid) && !uids.contains(harness.key.localUID)))
        }
    }

    @Test func olderListedHandoffDoesNotSuppressNewerPendingEditOrItsFailureBadge() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous]))
        let edit = PendingTile(
            key: harness.key, item: tile("p", second: 10).item, revision: UploadBackupRevision(rawValue: 3),
            handoff: nil, isSettled: false, badge: .waiting, displayName: "p", replaces: [previous.uid])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        let uploading = await settle(presenter)
        #expect(uploading.items.map(\.uid) == [edit.item.uid])
        #expect(uploading.localUIDs == [edit.item.uid])
        let failed = PendingTile(
            key: edit.key, item: edit.item, revision: edit.revision, handoff: nil, isSettled: false,
            badge: .attention, displayName: "p", replaces: edit.replaces)
        presenter.setPending(pending([failed], membership: 2), enabled: true)
        let attention = await settle(presenter)
        #expect(attention.items.map(\.uid) == [edit.item.uid])
        #expect(attention.uploadBadges[edit.item.uid] == .attention)
        presenter.reset()
    }

    @Test(arguments: [false, true])
    func newerEditWithoutListedHandoffHidesOlderCommittedRemote(unlistedHandoff: Bool) async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        var presentations: [PendingTimelinePresentation] = []
        presenter.onChange = { presentations.append($0) }
        let edit = PendingTile(
            key: harness.key, item: tile("p", second: 10).item, revision: UploadBackupRevision(rawValue: 3),
            handoff: unlistedHandoff ? remote("unlisted", second: 10).uid : nil,
            isSettled: false, badge: .waiting, displayName: "p")
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous]))
        #expect(await settle(presenter).items.map(\.uid) == [edit.item.uid])
        for presentation in presentations {
            let uids = Set(presentation.items.map(\.uid))
            #expect(!uids.contains(previous.uid) || !uids.contains(edit.item.uid))
        }
        presenter.reset()
    }

    @Test(arguments: ["exclude", "missing"])
    func removedPendingSourceDropsLedgerAndShowsEarlierPhotoAgain(removal: String) async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        let revision = UploadBackupRevision(rawValue: 2)
        harness.enqueue(revision: 2, state: .uploading)
        harness.recorder.recordUploadEvidence(source: harness.source, revision: revision, replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [original.uid])
        let other = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "other", resource: .primary)
        harness.recorder.recordUploadEvidence(source: other, revision: revision, replaces: [original.uid])
        await harness.coordinator.start()
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous]))
        presenter.setPending(await harness.coordinator.currentSnapshot(), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [previous.uid])
        if removal == "exclude" {
            #expect(await harness.coordinator.exclude([harness.key.localUID]))
        } else {
            await harness.coordinator.noteSourcesMissing([harness.key.localUID])
        }
        let removed = await harness.wait { $0.tiles.isEmpty }
        #expect(harness.recorder.replacementLedger.evidence(for: harness.key, revision: revision) == nil)
        #expect(
            harness.recorder.replacementLedger.evidence(
                for: harness.key, revision: UploadBackupRevision(rawValue: 3)) == nil)
        #expect(harness.recorder.replacementLedger.replacementHandoffs().isEmpty)
        #expect(harness.recorder.replacementLedger.evidence(for: PendingSourceKey(other), revision: revision) != nil)
        presenter.setPending(removed, enabled: true)
        #expect(Set(await settle(presenter).items.map(\.uid)) == [original.uid, previous.uid])
        presenter.reset()
        await harness.coordinator.close()
    }

    @Test func remoteFirstHoldPrefersNewestAncestorAndKeepsItsPositionAfterDeadline() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let clock = TestClock(base)
        let before = remote("a-before", second: 10)
        let original = remote("b-original", second: 10)
        let between = remote("bc-between", second: 10)
        let previous = remote("c-previous", second: 10)
        let after = remote("d-after", second: 10)
        let newest = remote("z-newest", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [original.uid, previous.uid])
        harness.handoff(revision: 3, remote: newest.uid)
        let presenter = PendingTimelinePresenter(
            now: { clock.now },
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setRemote(TimelineSnapshot(orderedItems: [before, original, between, previous, after, newest]))
        #expect(await settle(presenter).items.map(\.uid) == [before.uid, between.uid, previous.uid, after.uid])
        clock.now = base.addingTimeInterval(PendingTimelinePresenter.tileWaitLimit + 1)
        let other = remote("other", second: 20)
        presenter.setRemote(
            TimelineSnapshot(orderedItems: [before, original, between, previous, after, newest, other]))
        #expect(
            await settle(presenter).items.map(\.uid) == [before.uid, between.uid, newest.uid, after.uid, other.uid])
        presenter.reset()
    }

    @Test func remoteFirstHoldDoesNotRevealAnAncestorHiddenAsTrashed() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        let newest = remote("newest", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [original.uid, previous.uid])
        harness.handoff(revision: 3, remote: newest.uid)
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        let settled = PendingTile(
            key: harness.key, item: tile("p", second: 10).item, revision: UploadBackupRevision(rawValue: 3),
            handoff: newest.uid, isSettled: true, badge: .backedUp, displayName: "p",
            replaces: [original.uid, previous.uid])
        presenter.setPending(pending([settled], membership: 1), enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous, newest]))
        #expect(await settle(presenter).items.map(\.uid) == [newest.uid])
        presenter.setPending(pending([], membership: 2), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [newest.uid])
        presenter.reset()
    }

    @Test func duplicatePendingTileKeysKeepOneVisiblePhoto() async {
        let presenter = PendingTimelinePresenter()
        let edit = tile("p", second: 10)
        presenter.setPending(pending([edit, edit], membership: 1), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [edit.item.uid])
        #expect(presenter.current.localUIDs == [edit.item.uid])
        presenter.reset()
    }

    @Test(arguments: [false, true])
    func successiveUnacknowledgedEditsNeverRestoreAnOlderPredecessor(previousListed: Bool) async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        let newest = remote("newest", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [previous.uid])
        harness.handoff(revision: 3, remote: newest.uid)
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        let edit = PendingTile(
            key: harness.key, item: tile("p", second: 10).item, revision: UploadBackupRevision(rawValue: 3),
            handoff: newest.uid, isSettled: false, badge: .uploading(step: 5), displayName: "p",
            replaces: [previous.uid])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        presenter.setRemote(
            TimelineSnapshot(orderedItems: previousListed ? [original, previous, newest] : [original, newest]))
        let presentation = await settle(presenter)
        #expect(presentation.items.map(\.uid) == [newest.uid])
        #expect(presentation.uploadBadges[newest.uid] == .uploading(step: 5))
        #expect(presentation.uploadBadges.handovers[newest.uid] == edit.item.uid)
        presenter.reset()
    }

    @Test func successiveEditsKeepTheOnlyListedAncestorUntilTheNewestTileArrives() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        let newest = remote("newest", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [previous.uid])
        harness.handoff(revision: 3, remote: newest.uid)
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setRemote(TimelineSnapshot(orderedItems: [original]))
        #expect(await settle(presenter).items.map(\.uid) == [original.uid])
        // Neither committed edit is listed yet, and no pending metadata has arrived.
        #expect(presenter.current.localUIDs.isEmpty)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, newest]))
        #expect(await settle(presenter).items.map(\.uid) == [original.uid])

        try harness.journal.addSuperseded(previous.uid, for: harness.source)
        try harness.journal.settle([previous.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.enqueue(revision: 1, state: .completed)
        harness.enqueue(revision: 2, state: .completed)
        harness.enqueue(revision: 3, state: .completed)
        await harness.coordinator.start()
        let settled = await harness.wait { $0.tiles.first?.revision == UploadBackupRevision(rawValue: 3) }
        #expect(settled.tiles.first?.isSettled == true)
        presenter.setPending(settled, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [newest.uid])
        #expect(presenter.current.uploadBadges.handovers[newest.uid] == harness.key.localUID)
        presenter.reset()
        await harness.coordinator.close()
    }

    @Test func successiveEditsKeepTheNewestListedAncestorWhenTheLatestCommitIsMissing() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let clock = TestClock(base)
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        let newest = remote("newest", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [previous.uid])
        harness.handoff(revision: 3, remote: newest.uid)
        let presenter = PendingTimelinePresenter(
            now: { clock.now },
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous]))
        #expect(await settle(presenter).items.map(\.uid) == [original.uid])
        clock.now = base.addingTimeInterval(PendingTimelinePresenter.tileWaitLimit + 1)
        // An identical snapshot does not merge again; another listed photo does.
        let other = remote("other", second: 20)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous, other]))
        #expect(Set(await settle(presenter).items.map(\.uid)) == [previous.uid, other.uid])
        presenter.reset()
    }

    @Test(arguments: ["restore", "listing", "limit"])
    func successiveEditAncestorsStayHiddenThroughAcknowledgmentAndRetirement(release: String) async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let clock = TestClock(base)
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        let newest = remote("newest", second: 10)
        try harness.journal.addSuperseded(original.uid, for: harness.source)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        try harness.journal.settle([original.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.recorder.settleUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), retired: [original.uid.nodeID])
        try harness.journal.addSuperseded(previous.uid, for: harness.source)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [previous.uid])
        harness.handoff(revision: 3, remote: newest.uid)
        try harness.journal.settle([previous.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.enqueue(revision: 1, state: .completed)
        harness.enqueue(revision: 2, state: .completed)
        harness.enqueue(revision: 3, state: .completed)
        await harness.coordinator.start()
        let settled = await harness.wait { $0.tiles.first?.revision == UploadBackupRevision(rawValue: 3) }
        #expect(settled.tiles.first?.isSettled == true)
        #expect(settled.tiles.first?.replaces == [previous.uid])
        let presenter = PendingTimelinePresenter(
            now: { clock.now },
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        let listed = TimelineSnapshot(orderedItems: [original, previous, newest])
        presenter.setRemote(listed)
        presenter.setPending(settled, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [newest.uid])

        await harness.coordinator.noteRemotePresence([harness.key])
        #expect(harness.recorder.replacementLedger.replacementHandoffs().isEmpty)
        let retired = await harness.wait { $0.tiles.isEmpty }
        presenter.setPending(retired, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [newest.uid])

        switch release {
        case "restore":
            presenter.showRestored([original.uid])
            #expect(Set(await settle(presenter).items.map(\.uid)) == [original.uid, newest.uid])
        case "listing":
            presenter.setRemote(TimelineSnapshot(orderedItems: [newest]))
            #expect(await settle(presenter).items.map(\.uid) == [newest.uid])
            presenter.setRemote(listed)
            #expect(Set(await settle(presenter).items.map(\.uid)) == [original.uid, previous.uid, newest.uid])
        default:
            clock.now = base.addingTimeInterval(PendingTimelinePresenter.trashedHideLimit + 1)
            // An identical snapshot does not merge again; another listed photo does.
            let other = remote("other", second: 20)
            presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous, newest, other]))
            #expect(
                Set(await settle(presenter).items.map(\.uid)) == [original.uid, previous.uid, newest.uid, other.uid])
        }
        presenter.reset()
        await harness.coordinator.close()
    }

    @Test func unsettledOlderAncestorShowsAfterNewerSettledEditIsAcknowledged() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        let newest = remote("newest", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        try harness.journal.addSuperseded(previous.uid, for: harness.source)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), replaces: [original.uid, previous.uid])
        harness.handoff(revision: 3, remote: newest.uid)
        try harness.journal.settle([previous.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.recorder.settleUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 3), retired: [previous.uid.nodeID])
        harness.enqueue(revision: 2, state: .completed)
        harness.enqueue(revision: 3, state: .completed)
        await harness.coordinator.start()
        let settled = await harness.wait {
            $0.tiles.first?.revision == UploadBackupRevision(rawValue: 3) && $0.tiles.first?.isSettled == true
        }
        #expect(settled.tiles.first?.replaces == [previous.uid])
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous, newest]))
        presenter.setPending(settled, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [newest.uid])

        await harness.coordinator.noteRemotePresence([harness.key])
        let retired = await harness.wait { $0.tiles.isEmpty }
        presenter.setPending(retired, enabled: true)
        #expect(Set(await settle(presenter).items.map(\.uid)) == [original.uid, newest.uid])
        let other = remote("other", second: 20)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous, newest, other]))
        #expect(Set(await settle(presenter).items.map(\.uid)) == [original.uid, newest.uid, other.uid])
        presenter.reset()
        await harness.coordinator.close()
    }

    @Test func restoredOlderCommittedRemoteShowsWhileNewerEditHasNoListedHandoff() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let original = remote("original", second: 10)
        let previous = remote("previous", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [original.uid])
        harness.handoff(revision: 2, remote: previous.uid)
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        let edit = PendingTile(
            key: harness.key, item: tile("p", second: 10).item, revision: UploadBackupRevision(rawValue: 3),
            handoff: nil, isSettled: false, badge: .waiting, displayName: "p")
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, previous]))
        #expect(await settle(presenter).items.map(\.uid) == [edit.item.uid])
        presenter.showRestored([previous.uid])
        let restored = await settle(presenter)
        #expect(Set(restored.items.map(\.uid)) == [previous.uid, edit.item.uid])
        #expect(restored.localUIDs == [edit.item.uid])
        #expect(restored.uploadBadges[edit.item.uid] == .waiting)
        presenter.reset()
    }

    @Test func missingSourceIgnoresLateHandoffAndAcceptsHigherRevision() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let clock = TestClock(base)
        let original = remote("original", second: 10)
        let uploaded = remote("uploaded", second: 10)
        let revision = UploadBackupRevision(rawValue: 2)
        try harness.journal.addSuperseded(original.uid, for: harness.source)
        harness.enqueue(revision: 2, state: .uploading)
        harness.recorder.recordUploadEvidence(source: harness.source, revision: revision, replaces: [original.uid])
        await harness.coordinator.start()
        let uploading = await harness.wait { $0.tiles.first?.revision == revision && $0.tiles.first?.handoff == nil }
        let presenter = PendingTimelinePresenter(
            now: { clock.now },
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setRemote(TimelineSnapshot(orderedItems: [original]))
        presenter.setPending(uploading, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [harness.key.localUID])
        await harness.coordinator.noteSourcesMissing([harness.key.localUID])
        presenter.setPending(await harness.wait { $0.tiles.isEmpty }, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [original.uid])

        harness.handoff(revision: 2, remote: uploaded.uid)
        let missing = await harness.wait { $0.tiles.isEmpty }
        presenter.setPending(missing, enabled: true)
        #expect(harness.recorder.replacementLedger.evidence(for: harness.key, revision: revision) == nil)
        #expect(harness.recorder.replacementLedger.replacementHandoffs().isEmpty)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, uploaded]))
        _ = await settle(presenter)
        clock.now = base.addingTimeInterval(PendingTimelinePresenter.tileWaitLimit + 1)
        let other = remote("other", second: 20)
        presenter.setRemote(TimelineSnapshot(orderedItems: [original, uploaded, other]))
        #expect(Set(await settle(presenter).items.map(\.uid)) == [original.uid, uploaded.uid, other.uid])

        let newer = UploadBackupRevision(rawValue: 3)
        harness.recorder.recordUploadEvidence(source: harness.source, revision: newer, replaces: [original.uid])
        harness.handoff(revision: 3, remote: remote("newer", second: 10).uid)
        #expect(
            harness.recorder.replacementLedger.evidence(for: harness.key, revision: newer)?.replaces == [original.uid])
        #expect(harness.recorder.replacementLedger.replacementHandoffs().map(\.evidence.revision) == [newer])
        presenter.reset()
        await harness.coordinator.close()
    }

    @Test func remoteFirstHoldAppliedAfterItsDeadlineReleasesWithoutAnotherInput() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let clock = TestClock(base)
        let gate = EditMembershipGate()
        let presenter = PendingTimelinePresenter(
            now: { clock.now },
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() },
            sleep: { duration in
                if duration > .zero { await gate.wait() }
            })
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        _ = await settle(presenter)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 1), replaces: [earlier.uid])
        harness.handoff(revision: 1, remote: uploaded.uid)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [earlier.uid])
        let before = presenter.current.revision
        // The merge captures a pre-deadline time. Apply reads the advanced clock after the deadline.
        clock.advanceAfterNextRead(to: base.addingTimeInterval(PendingTimelinePresenter.tileWaitLimit + 1))
        presenter.setRemote(TimelineSnapshot(orderedItems: [uploaded]))
        let released = await settle(presenter)
        #expect(released.items.map(\.uid) == [uploaded.uid])
        #expect(released.revision == before + 2, "one late hold and one autonomous rebuild, without a timer loop")
        #expect(await settle(presenter).revision == released.revision)
        presenter.reset()
        await gate.release()
    }

    @Test func explicitDisabledBackupStopsTheDurableReplacementOverlay() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter(replacementLookup: { [ledger = harness.recorder.replacementLedger] in
            ledger.replacementHandoffs()
        })
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 1), replaces: [earlier.uid])
        harness.handoff(revision: 1, remote: uploaded.uid)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [earlier.uid])
        presenter.setPending(.empty, enabled: false)
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier.uid, uploaded.uid])
    }

    @Test func laterEditReplacesOnlyCurrentMainAndKeepsRestoredHistoryVisible() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter(replacementLookup: { [ledger = harness.recorder.replacementLedger] in
            ledger.replacementHandoffs()
        })
        let historical = remote("historical", second: 10)
        let current = remote("current", second: 10)
        let uploaded = remote("edit", second: 10)
        // The old journal still contains a main and its related resource, previously retired and now restored remotely.
        try harness.journal.addSuperseded(historical.uid, for: harness.source)
        try harness.journal.settle(
            [historical.uid.nodeID], related: ["historical-video"], trashed: true, for: harness.source)
        await harness.coordinator.start()
        try harness.journal.addSuperseded(current.uid, for: harness.source)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [current.uid])
        try harness.journal.settle([current.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.handoff(revision: 2, remote: uploaded.uid)
        harness.enqueue(revision: 2, state: .completed)
        let settled = await harness.wait { $0.tiles.first?.isSettled == true }
        #expect(settled.tiles.first?.replaces == [current.uid])
        presenter.setPending(settled, enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: [historical, current, uploaded]))
        #expect(Set(await settle(presenter).items.map(\.uid)) == [historical.uid, uploaded.uid])
        await harness.coordinator.close()
    }

    @Test func uploadSettledInsideMembershipIntervalNeverShowsBothPhotos() async throws {
        let gate = EditMembershipGate()
        let harness = try EditPendingHarness(
            date: base, membershipInterval: .seconds(60),
            sleep: { duration in
                await gate.wait(duration)
            })
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        _ = await settle(presenter)
        harness.enqueue(revision: 1, state: .completed)
        harness.enqueue(revision: 2, state: .queuedForUpload)
        await harness.coordinator.start()
        let initial = await harness.coordinator.currentSnapshot()
        #expect(initial.tiles.isEmpty)
        try harness.journal.addSuperseded(earlier.uid, for: harness.source)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [earlier.uid])
        harness.handoff(revision: 2, remote: uploaded.uid)
        try harness.journal.settle([earlier.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.recorder.settleUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), retired: [earlier.uid.nodeID])
        harness.enqueue(revision: 2, state: .completed)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [earlier.uid])
        // The coordinator handled the new rows and holds their membership publish for the rest of the 60 s interval.
        await gate.waitForSleep(in: .seconds(1) ... .seconds(60))
        #expect(await harness.coordinator.currentSnapshot().membershipRevision == initial.membershipRevision)
        await gate.release()
        let settled = await harness.wait { $0.tiles.first?.isSettled == true }
        presenter.setPending(settled, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])
        #expect(presenter.current.uploadBadges.handovers[uploaded.uid] == harness.key.localUID)
        await harness.coordinator.close()
    }

    @Test func rebuiltRecorderCoordinatorAndPresenterKeepSettledReplacement() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        harness.enqueue(revision: 2, state: .uploading)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [earlier.uid])
        harness.handoff(revision: 2, remote: uploaded.uid)
        try harness.journal.addSuperseded(earlier.uid, for: harness.source)
        try harness.journal.settle([earlier.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.enqueue(revision: 2, state: .completed)
        await harness.coordinator.start()
        let first = await harness.coordinator.currentSnapshot()
        #expect(first.tiles.first?.replaces == [earlier.uid])
        await harness.rebuild()
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        presenter.setPending(await harness.coordinator.currentSnapshot(), enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])
        await harness.coordinator.close()
    }

    @Test func remoteFirstWaitIsBoundedAndKeepsTheEarlierImageAfterListingDropsIt() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let clock = TestClock(base)
        let presenter = PendingTimelinePresenter(
            now: { clock.now },
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in
                ledger.replacementHandoffs()
            })
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        _ = await settle(presenter)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 1), replaces: [earlier.uid])
        harness.handoff(revision: 1, remote: uploaded.uid)
        presenter.setRemote(TimelineSnapshot(orderedItems: [uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [earlier.uid])
        clock.now = base.addingTimeInterval(PendingTimelinePresenter.tileWaitLimit + 1)
        presenter.setPending(pending([], membership: 1), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])
    }

    @Test func keptEarlierPhotoReturnsAfterSettlement() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter(
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in ledger.replacementHandoffs() })
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 1), replaces: [earlier.uid])
        harness.handoff(revision: 1, remote: uploaded.uid)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        presenter.setPending(pending([tile("p", second: 10, replaces: [earlier.uid])], membership: 1), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])
        harness.recorder.settleUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 1), retired: [])
        // A stale snapshot must still use the recorder's narrowed replacement record.
        presenter.setPending(
            pending([tile("p", second: 10, settled: true, replaces: [earlier.uid])], membership: 2), enabled: true)
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier.uid, uploaded.uid])
    }

    @Test func trashMergesPendingPhotosNewestFirst() {
        let newest = remote("newest", second: 30)
        let oldest = remote("oldest", second: 0)
        let pending = tile("pending", second: 10).item
        let trash = PendingTrashPresentation(items: [pending])

        #expect(trash.merged(intoNewestFirst: [newest, oldest]).map(\.uid) == [newest.uid, pending.uid, oldest.uid])
        #expect(trash.badges[pending.uid] == .notBackedUp)
        #expect(PendingTrashPresentation.empty.merged(intoNewestFirst: [newest]).map(\.uid) == [newest.uid])
    }

    @Test func editedLocalPhotoGetsANewContentEpochOnceItsImageLoaded() async {
        let presenter = PendingTimelinePresenter()
        var revisedUIDs: [PhotoUID] = []
        presenter.onFeedUpdate = { _, _, revised in revisedUIDs += revised }
        let original = tile("b", second: 10)
        presenter.setPending(pending([original], membership: 1), enabled: true)
        let before = await settle(presenter)
        #expect(before.uploadBadges.contentEpochs.isEmpty)

        let edited = PendingTile(
            key: original.key, item: original.item, revision: UploadBackupRevision(rawValue: 2), handoff: nil,
            isSettled: false, badge: .waiting, displayName: "b")
        presenter.setPending(pending([edited], membership: 2), enabled: true)
        let after = await settle(presenter)

        #expect(revisedUIDs == [original.item.uid])
        #expect(after.uploadBadges.contentEpochs.isEmpty, "the tile keeps its image until the new one loaded")

        presenter.noteContentRefreshed([original.item.uid, tile("gone", second: 0).item.uid])
        var tracker = PendingContentEpochTracker()
        #expect(tracker.changes(in: presenter.current.uploadBadges.contentEpochs) == [original.item.uid])
        #expect(
            tracker.changes(in: presenter.current.uploadBadges.contentEpochs).isEmpty, "one change invalidates once")
    }

    // MARK: - Edits of backed-up photos

    /// Proton photos in the same second as the edited photo, so only the anchor decides the place.
    private func sameSecond(_ nodes: [String]) -> [PhotoItem] {
        nodes.map { remote($0, second: 10) }.sorted(by: TimelineOrder.areInIncreasingOrder)
    }

    @Test(arguments: [UploadBackupSyncQueueState.checking, .discovered])
    func anEditWaitsForItsReplacementIdentity(
        state: UploadBackupSyncQueueState
    ) async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter()
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        var presentations: [PendingTimelinePresentation] = []
        presenter.onChange = { presentations.append($0) }
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        _ = await settle(presenter)

        // An older retired revision does not prove that this edit replaces the currently listed photo.
        try harness.journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "older"), for: harness.source)
        try harness.journal.settle(["older"], related: [], trashed: true, for: harness.source)
        harness.enqueue(revision: 1, state: .completed)
        harness.enqueue(revision: 2, state: state)
        await harness.coordinator.start()
        let checking = await harness.wait { $0.tiles.isEmpty }
        presenter.setPending(checking, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [earlier.uid])

        try harness.journal.addSuperseded(earlier.uid, for: harness.source)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [earlier.uid])
        harness.enqueue(revision: 2, state: .uploading)
        let uploading = await harness.wait { $0.tiles.first?.revision == UploadBackupRevision(rawValue: 2) }
        presenter.setPending(uploading, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [harness.key.localUID])

        // The new main may be listed before the runner trashes the earlier main.
        harness.handoff(revision: 2, remote: uploaded.uid)
        let committed = await harness.wait { $0.tiles.first?.handoff == uploaded.uid }
        presenter.setPending(committed, enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])

        try harness.journal.settle([earlier.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.enqueue(revision: 2, state: .completed)
        let settled = await harness.wait { $0.tiles.first?.isSettled == true }
        #expect(
            settled.tiles.first?.replaces == [earlier.uid], "this revision never recovers the older retired history")
        presenter.setPending(settled, enabled: true)
        _ = await settle(presenter)
        await harness.coordinator.noteRemotePresence([harness.key])
        presenter.setPending(await harness.wait { $0.tiles.isEmpty }, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])

        for presentation in presentations {
            let uids = Set(presentation.items.map(\.uid))
            #expect(!uids.isEmpty, "the earlier photo stays until the edit can take its place")
            #expect(
                !uids.contains(earlier.uid)
                    || (!uids.contains(harness.key.localUID) && !uids.contains(uploaded.uid)),
                "no published snapshot shows the earlier photo beside the edit")
        }
        await harness.coordinator.close()
    }

    @Test(arguments: [UploadBackupSyncQueueState.uploading, .completed])
    func anEditThatRetiresBeforeItsFirstTilePublicationNeverShowsBesideItsEarlierPhoto(
        state: UploadBackupSyncQueueState
    ) async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter()
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        var presentations: [PendingTimelinePresentation] = []
        presenter.onChange = { presentations.append($0) }
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        _ = await settle(presenter)

        await harness.coordinator.start()
        // The runner retires the earlier photo before this process consumes its upload evidence.
        // No pending tile has read the superseded identity yet.
        try harness.journal.addSuperseded(earlier.uid, for: harness.source)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [earlier.uid])
        try harness.journal.settle([earlier.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.handoff(revision: 2, remote: uploaded.uid)
        harness.enqueue(revision: 2, state: state)
        presenter.setPending(
            await harness.wait { $0.tiles.first?.handoff == uploaded.uid && $0.tiles.first?.replaces.isEmpty == false },
            enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [harness.key.localUID])

        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])
        harness.enqueue(revision: 2, state: .completed)
        presenter.setPending(await harness.wait { $0.tiles.first?.isSettled == true }, enabled: true)
        _ = await settle(presenter)
        await harness.coordinator.noteRemotePresence([harness.key])
        presenter.setPending(await harness.wait { $0.tiles.isEmpty }, enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])

        for presentation in presentations {
            let uids = Set(presentation.items.map(\.uid))
            #expect(!uids.isEmpty)
            #expect(
                !uids.contains(earlier.uid)
                    || (!uids.contains(harness.key.localUID) && !uids.contains(uploaded.uid)))
        }
        await harness.coordinator.close()
    }

    @Test func anUnchangedRecheckDoesNotHideARestoredEarlierPhoto() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let presenter = PendingTimelinePresenter()
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        harness.enqueue(revision: 1, state: .completed)
        try harness.journal.addSuperseded(earlier.uid, for: harness.source)
        harness.enqueue(revision: 2, state: .uploading)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 2), replaces: [earlier.uid])
        await harness.coordinator.start()
        presenter.setPending(await harness.coordinator.currentSnapshot(), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [harness.key.localUID])

        try harness.journal.settle([earlier.uid.nodeID], related: [], trashed: true, for: harness.source)
        harness.handoff(revision: 2, remote: uploaded.uid)
        harness.enqueue(revision: 2, state: .completed)
        presenter.setPending(await harness.wait { $0.tiles.first?.isSettled == true }, enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: [uploaded]))
        #expect(await settle(presenter).items.map(\.uid) == [uploaded.uid])
        await harness.coordinator.noteRemotePresence([harness.key])
        presenter.setPending(await harness.wait { $0.tiles.isEmpty }, enabled: true)
        _ = await settle(presenter)

        presenter.showRestored([earlier.uid])
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier, uploaded]))
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier.uid, uploaded.uid])

        // The manifest fast path settles a later recheck of B without uploading or replacing anything.
        harness.enqueue(revision: 3, state: .checking)
        harness.handoff(revision: 3, remote: uploaded.uid, kind: .deduplicated)
        harness.enqueue(revision: 3, state: .alreadyBackedUp)
        let rechecked = await harness.wait {
            $0.tiles.first?.revision == UploadBackupRevision(rawValue: 3) && $0.tiles.first?.isSettled == true
        }
        #expect(rechecked.tiles.first?.replaces.isEmpty == true)
        presenter.setPending(rechecked, enabled: true)
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier.uid, uploaded.uid])
        await harness.coordinator.close()
    }

    @Test func theTileOfAnEditTakesThePlaceOfItsEarlierPhotoAndHidesIt() async {
        let presenter = PendingTimelinePresenter()
        let listed = sameSecond(["a", "earlier", "z"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let edit = tile("p", second: 10, replaces: [PhotoUID(volumeID: "", nodeID: "earlier")])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        let presentation = await settle(presenter)

        #expect(
            presentation.items.map(\.uid) == listed.map { $0.uid.nodeID == "earlier" ? edit.item.uid : $0.uid },
            "one photo, at the earlier photo's place")
        #expect(!presentation.isCanonical)
    }

    @Test func theProtonPhotoOfAnEditKeepsThePlaceAndContinuesTheTileImage() async {
        let presenter = PendingTimelinePresenter()
        let listed = sameSecond(["a", "earlier", "z"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let edit = tile("p", second: 10, handoff: uploaded, badge: .uploading(step: 10), replaces: [earlier])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        _ = await settle(presenter)

        presenter.setRemote(TimelineSnapshot(orderedItems: listed + [remote("0-new", second: 10)]))
        let presentation = await settle(presenter)

        #expect(presentation.items.map(\.uid) == listed.map { $0.uid == earlier ? uploaded : $0.uid })
        #expect(
            presentation.uploadBadges.handovers[uploaded] == edit.item.uid,
            "the Proton photo continues the tile's texture, never the earlier photo's")
    }

    @Test func anEditPublishesEachReplacementStepForAnOpenViewer() async {
        let presenter = PendingTimelinePresenter()
        let listed = sameSecond(["a", "earlier", "z"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let edit = tile("p", second: 10, handoff: uploaded, badge: .uploading(step: 10), replaces: [earlier])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        let pendingEdit = await settle(presenter)

        #expect(pendingEdit.replacements == [earlier: edit.item.uid], "the tile of the edit replaces the earlier photo")

        presenter.setRemote(TimelineSnapshot(orderedItems: listed + [remote("0-new", second: 10)]))
        let uploadedEdit = await settle(presenter)

        #expect(uploadedEdit.replacements[earlier] == edit.item.uid)
        #expect(uploadedEdit.replacements[edit.item.uid] == uploaded, "the Proton photo of the edit replaces its tile")
    }

    @Test func anEditStillReplacesTheEarlierPhotoAfterTheListingDropsItUnlessItWasRestored() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: sameSecond(["a", "z"])))
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let edit = tile("p", second: 10, handoff: uploaded, badge: .uploading(step: 10), replaces: [earlier])
        presenter.setPending(pending([edit], membership: 1), enabled: true)

        #expect(await settle(presenter).replacements[earlier] == edit.item.uid, "an open viewer still shows it")

        presenter.showRestored([earlier])

        #expect(await settle(presenter).replacements[earlier] == nil, "a restored photo keeps its own page")
    }

    @Test func aRemoteFirstEditReplacesTheEarlierPhotoAfterTheListingDropsIt() async throws {
        let harness = try EditPendingHarness(date: base)
        defer { harness.closeStores() }
        let clock = TestClock(base)
        let presenter = PendingTimelinePresenter(
            now: { clock.now },
            replacementLookup: { [ledger = harness.recorder.replacementLedger] in
                ledger.replacementHandoffs()
            })
        let earlier = remote("earlier", second: 10)
        let uploaded = remote("edit", second: 10)
        presenter.setRemote(TimelineSnapshot(orderedItems: [earlier]))
        _ = await settle(presenter)
        harness.recorder.recordUploadEvidence(
            source: harness.source, revision: UploadBackupRevision(rawValue: 1), replaces: [earlier.uid])
        harness.handoff(revision: 1, remote: uploaded.uid)
        presenter.setRemote(TimelineSnapshot(orderedItems: [uploaded]))
        _ = await settle(presenter)
        clock.now = base.addingTimeInterval(PendingTimelinePresenter.tileWaitLimit + 1)
        presenter.setPending(pending([], membership: 1), enabled: true)
        let presentation = await settle(presenter)

        #expect(presentation.items.map(\.uid) == [uploaded.uid])
        #expect(presentation.replacements[earlier.uid] == uploaded.uid, "an open viewer follows the edit")
    }

    @Test func theSupportReportCountsWhatTheGridHidesWithoutIdentifiers() async {
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let presenter = PendingTimelinePresenter(now: { Date() }, supportSources: sources)
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        presenter.setRemote(TimelineSnapshot(orderedItems: sameSecond(["a", "earlier", "0-new"])))
        let done = tile("p", second: 10, handoff: uploaded, settled: true, badge: .done, replaces: [earlier])
        presenter.setPending(pending([done], membership: 1), enabled: true)
        _ = await settle(presenter)

        let grid = sources.pendingGridSnapshot()
        #expect(grid.merges >= 1)
        #expect(grid.pendingTiles == 1)
        #expect(grid.remotePhotosListed == 3)
        #expect(grid.remotePhotosHidden == 1)
        #expect(grid.trashedEarlierPhotosHidden == 1)
        #expect(grid.lastMergeAt != nil)
    }

    @Test func aTrashedEarlierPhotoStaysHiddenUntilTheListingDropsIt() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["a", "earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let done = tile("p", second: 10, handoff: uploaded, settled: true, badge: .done, replaces: [earlier])
        presenter.setPending(pending([done], membership: 1), enabled: true)
        _ = await settle(presenter)

        // The tile retires, but the listing still returns the trashed photo.
        presenter.setPending(pending([], membership: 2), enabled: true)
        let lagging = await settle(presenter)
        #expect(!lagging.items.map(\.uid).contains(earlier))
        #expect(lagging.items.map(\.uid).contains(uploaded))

        let withoutEarlier = listed.filter { $0.uid != earlier }
        presenter.setRemote(TimelineSnapshot(orderedItems: withoutEarlier))
        _ = await settle(presenter)
        // The person restores it from Recently Deleted: it shows again.
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let restored = await settle(presenter)
        #expect(restored.items.map(\.uid).contains(earlier))
    }

    @Test func aTrashedPhotoThatThePersonRestoredShowsAgainAtTheLatestAfterTheLimit() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let presenter = PendingTimelinePresenter(now: { clock.now })
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: uploaded, settled: true, badge: .done, replaces: [earlier])],
                membership: 1),
            enabled: true)
        _ = await settle(presenter)
        presenter.setPending(pending([], membership: 2), enabled: true)
        let hidden = await settle(presenter)
        #expect(hidden.items.map(\.uid) == [uploaded])

        // Restored on another device before the listing dropped it: the listing keeps returning it.
        clock.now = clock.now.addingTimeInterval(PendingTimelinePresenter.trashedHideLimit + 1)
        presenter.setRemote(TimelineSnapshot(orderedItems: listed + [remote("b", second: 20)]))
        let restored = await settle(presenter)
        #expect(restored.items.map(\.uid).contains(earlier))
    }

    @Test func aTrashedPhotoRestoredInThisAppShowsAtOnce() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let done = tile("p", second: 10, handoff: uploaded, settled: true, badge: .done, replaces: [earlier])
        presenter.setPending(pending([done], membership: 1), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded])

        presenter.showRestored([earlier])
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier, uploaded], "while the tile still shows")
        presenter.setPending(pending([], membership: 2), enabled: true)
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier, uploaded], "and after it retired")
    }

    @Test func aRestoreKeepsOnlyTheEditsOfItsMomentFromHidingThePhoto() async {
        let presenter = PendingTimelinePresenter()
        let photo = PhotoUID(volumeID: "vol", nodeID: "photo")
        presenter.setRemote(TimelineSnapshot(orderedItems: sameSecond(["a", "photo"])))
        // Restored before any edit replaced it.
        presenter.showRestored([photo])
        _ = await settle(presenter)

        let edit = tile("p", second: 10, replaces: [photo])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        let edited = await settle(presenter)
        #expect(!edited.items.map(\.uid).contains(photo), "a later edit replaces it")

        presenter.showRestored([photo])
        let restored = await settle(presenter)
        #expect(restored.items.map(\.uid).contains(photo), "restored while this edit replaced it")

        let secondEdit = PendingTile(
            key: edit.key, item: edit.item, revision: UploadBackupRevision(rawValue: 2), handoff: nil,
            isSettled: false, badge: .waiting, displayName: "p", replaces: [photo])
        presenter.setPending(pending([secondEdit], membership: 2), enabled: true)
        let editedAgain = await settle(presenter)
        #expect(!editedAgain.items.map(\.uid).contains(photo), "a second edit replaces it again")
    }

    @Test func aSecondEditTakesThePlaceWhereTheFirstEditShows() async {
        let presenter = PendingTimelinePresenter()
        let original = PhotoUID(volumeID: "vol", nodeID: "m-original")
        let first = PhotoUID(volumeID: "vol", nodeID: "z-first")
        let second = PhotoUID(volumeID: "vol", nodeID: "0-second")
        let listed = sameSecond(["a", "m-original", "q"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: first, badge: .uploading(step: 5), replaces: [original])],
                membership: 1),
            enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: listed + [remote("z-first", second: 10)]))
        let firstEdit = await settle(presenter)
        let place = listed.map { $0.uid == original ? first : $0.uid }
        #expect(firstEdit.items.map(\.uid) == place)

        // The first tile retired and the listing dropped the original; then the photo is edited again.
        let afterFirst = sameSecond(["a", "q", "z-first"])
        presenter.setRemote(TimelineSnapshot(orderedItems: afterFirst))
        presenter.setPending(pending([], membership: 2), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == place)
        let edit = tile("p", second: 10, replaces: [first])
        presenter.setPending(pending([edit], membership: 3), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == listed.map { $0.uid == original ? edit.item.uid : $0.uid })

        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: second, badge: .uploading(step: 5), replaces: [first])],
                membership: 4),
            enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: afterFirst + [remote("0-second", second: 10)]))
        #expect(await settle(presenter).items.map(\.uid) == listed.map { $0.uid == original ? second : $0.uid })
    }

    @Test func anEarlierPhotoThatTheReplacementKeptShowsAgain() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: uploaded, badge: .uploading(step: 5), replaces: [earlier])],
                membership: 1),
            enabled: true)
        let uploading = await settle(presenter)
        #expect(uploading.items.map(\.uid) == [uploaded])

        presenter.setPending(
            pending([tile("p", second: 10, handoff: uploaded, settled: true, badge: .done)], membership: 2),
            enabled: true)
        let kept = await settle(presenter)
        #expect(Set(kept.items.map(\.uid)) == [earlier, uploaded])
    }

    @Test func anUndoThatHandsOverToTheEarlierPhotoKeepsIt() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        presenter.setRemote(TimelineSnapshot(orderedItems: sameSecond(["earlier"])))
        presenter.setPending(
            pending([tile("p", second: 10, handoff: earlier, badge: .done, replaces: [earlier])], membership: 1),
            enabled: true)
        let presentation = await settle(presenter)

        #expect(presentation.items.map(\.uid) == [earlier])
    }

    @Test func aTileThatShowsAgainAfterAnotherEditReloadsItsImage() async {
        let presenter = PendingTimelinePresenter()
        var revisedUIDs: [PhotoUID] = []
        presenter.onFeedUpdate = { _, _, revised in revisedUIDs += revised }
        let first = tile("p", second: 10)
        presenter.setPending(pending([first], membership: 1), enabled: true)
        _ = await settle(presenter)
        // The first edit uploaded and its tile retired.
        presenter.setPending(pending([], membership: 2), enabled: true)
        _ = await settle(presenter)

        let again = PendingTile(
            key: first.key, item: first.item, revision: UploadBackupRevision(rawValue: 2), handoff: nil,
            isSettled: false, badge: .waiting, displayName: "p")
        presenter.setPending(pending([again], membership: 3), enabled: true)
        _ = await settle(presenter)

        #expect(revisedUIDs == [first.item.uid], "the grid and the feed still hold the image of the first edit")
    }

    @Test func pendingPhotosSortIntoTheTimeline() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0), remote("c", second: 20)]))
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: true)
        let presentation = await settle(presenter)

        #expect(presentation.items.map(\.uid.nodeID) == ["a", "b", "c"])
        #expect(presentation.localUIDs == [PendingSourceKey(kind: .photoLibraryAsset, identifier: "b").localUID])
        #expect(!presentation.isCanonical)
    }

    @Test func handedOverPhotoKeepsThePendingPosition() async {
        // In the same second, the canonical order puts the new Proton photo ("zz") after "m", while the pending
        // tile ("local.photos" volume) sorted before "m". The anchor keeps the pending position.
        let presenter = PendingTimelinePresenter()
        var remotes = [remote("m", second: 5)]
        presenter.setRemote(TimelineSnapshot(orderedItems: remotes))
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "zz")
        presenter.setPending(
            pending([tile("p", second: 5, handoff: uploaded, badge: .uploading(step: 10))], membership: 1),
            enabled: true)
        let before = await settle(presenter)
        #expect(before.items.map(\.uid.volumeID) == ["local.photos", "vol"])

        var presence: Set<PendingSourceKey> = []
        presenter.onRemotePresence = { presence.formUnion($0) }
        remotes.append(PhotoItem(uid: uploaded, captureTime: base.addingTimeInterval(5), mediaType: "image/heic"))
        presenter.setRemote(TimelineSnapshot(orderedItems: remotes))
        let after = await settle(presenter)

        #expect(after.items.map(\.uid) == [uploaded, remotes[0].uid], "the Proton photo takes the tile's place")
        #expect(after.localUIDs.isEmpty)
        #expect(after.uploadBadges[uploaded] == .uploading(step: 10), "a still-uploading source keeps its progress")
        #expect(after.replacements.isEmpty, "a plain upload continues the same picture; an open viewer keeps its page")
        #expect(presence == [PendingSourceKey(kind: .photoLibraryAsset, identifier: "p")])

        // Grids let the Proton photo draw the pending tile's texture, once.
        let local = before.items[0].uid
        #expect(after.uploadBadges.handovers == [uploaded: local])
        var tracker = PendingHandoverTracker()
        #expect(tracker.newHandovers(in: after.uploadBadges.handovers).map(\.remote) == [uploaded])
        #expect(tracker.newHandovers(in: after.uploadBadges.handovers).isEmpty)
    }

    @Test func linkOnlyHandoffResolvesToThePhotosVolume() async {
        let presenter = PendingTimelinePresenter()
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "dup")
        presenter.setRemote(
            TimelineSnapshot(orderedItems: [PhotoItem(uid: uploaded, captureTime: base, mediaType: "image/jpeg")]))
        presenter.setPending(
            pending(
                [tile("d", second: 0, handoff: PhotoUID(volumeID: "", nodeID: "dup"), settled: true, badge: .done)],
                membership: 1),
            enabled: true)
        let presentation = await settle(presenter)
        #expect(presentation.items.map(\.uid) == [uploaded])
        #expect(presentation.uploadBadges[uploaded] == .done)
    }

    @Test func disabledBackupShowsOnlyProtonPhotos() async {
        let presenter = PendingTimelinePresenter()
        let canonical = TimelineSnapshot(orderedItems: [remote("a", second: 0)])
        presenter.setRemote(canonical)
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: false)
        let presentation = await settle(presenter)
        #expect(presentation.snapshot == canonical)
        #expect(presentation.isCanonical)
        #expect(presentation.uploadBadges.isEmpty)
    }

    @Test func aBadgeChangeKeepsTheGridMembership() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0)]))
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: true)
        let before = await settle(presenter)

        presenter.setPending(pending([tile("b", second: 10, badge: .done)], membership: 2), enabled: true)
        let after = await settle(presenter)

        #expect(after.revision != before.revision)
        #expect(after.membershipRevision == before.membershipRevision)
        #expect(after.snapshot == before.snapshot)
        #expect(after.uploadBadges[tile("b", second: 10).item.uid] == .done)
    }

    @Test func aNewPendingPhotoChangesTheGridMembership() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0)]))
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: true)
        let before = await settle(presenter)

        let (b, c) = (tile("b", second: 10), tile("c", second: 20))
        presenter.setPending(pending([b, c], membership: 2), enabled: true)
        let after = await settle(presenter)

        #expect(after.membershipRevision != before.membershipRevision)
        #expect(after.items.map(\.uid) == [remote("a", second: 0).uid, b.item.uid, c.item.uid])
    }

    @Test func progressChangesOnlyTheBadges() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0)]))
        let pendingTile = tile("b", second: 10)
        presenter.setPending(pending([pendingTile], membership: 1), enabled: true)
        let before = await settle(presenter)

        presenter.setPending(pending([pendingTile], membership: 1, progress: [pendingTile.item.uid: 12]), enabled: true)
        let after = presenter.current
        #expect(after.membershipRevision == before.membershipRevision)
        #expect(after.revision != before.revision)
        #expect(after.uploadBadges[pendingTile.item.uid] == .uploading(step: 12))
    }

    @Test func pausedBadgesReplaceOnlyWaitingAndUploadingApplePhotos() {
        let waiting = tile("w", second: 0).item.uid
        let uploading = tile("u", second: 1).item.uid
        let done = tile("d", second: 2).item.uid
        let attention = tile("a", second: 3).item.uid
        let notBackedUp = tile("n", second: 4).item.uid
        let file = PendingSourceKey(kind: .fileURL, identifier: "/f.heic").localUID
        let handedOver = PhotoUID(volumeID: "vol", nodeID: "h")
        let base: [PhotoUID: GridUploadBadge] = [
            waiting: .waiting, uploading: .waiting, done: .done, attention: .attention, notBackedUp: .notBackedUp,
            file: .waiting, handedOver: .waiting,
        ]
        let running = PendingUploadBadges(
            base: base, progress: [uploading: 7, handedOver: 3], handovers: [handedOver: tile("h", second: 5).item.uid])
        let paused = running.replacing(isPaused: true)

        #expect(paused[waiting] == .paused)
        #expect(paused[uploading] == .paused)
        #expect(paused[handedOver] == .paused, "a Proton photo whose Apple Photos source still uploads pauses too")
        #expect(paused[done] == .done, "a photo that just finished keeps its checkmark")
        #expect(paused[attention] == .attention)
        #expect(paused[notBackedUp] == .notBackedUp)
        #expect(paused[file] == .waiting, "watched Mac folders do not pause with the Apple Photos backup")
        #expect(paused != running, "hosts see a new value")

        let resumed = paused.replacing(isPaused: false)
        #expect(resumed[waiting] == .waiting)
        #expect(resumed[uploading] == .uploading(step: 7))
        #expect(resumed[handedOver] == .uploading(step: 3))
    }

    @Test func onlyAPausedPhotoTellsVoiceOverThatTheBackupIsPaused() {
        let waiting = tile("w", second: 0).item.uid
        let done = tile("d", second: 1).item.uid
        let badges = PendingUploadBadges(base: [waiting: .waiting, done: .done], isPaused: true)
        let description = badges.accessibilityDescription(for: waiting)
        #expect(description == L10n.string("a11y.upload_badge.paused"))
        #expect(description != "a11y.upload_badge.paused", "the catalog has the text")
        #expect(badges.accessibilityDescription(for: done) == nil)
        #expect(badges.replacing(isPaused: false).accessibilityDescription(for: waiting) == nil)
    }

    @Test func pausingAndResumingChangesOnlyTheBadges() async {
        let presenter = PendingTimelinePresenter()
        var published = 0
        presenter.onChange = { _ in published += 1 }
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0)]))
        let waiting = tile("w", second: 10)
        let uploading = tile("u", second: 11)
        let failed = tile("f", second: 12, badge: .attention)
        let tiles = [waiting, uploading, failed]
        presenter.setPending(pending(tiles, membership: 1, progress: [uploading.item.uid: 4]), enabled: true)
        let before = await settle(presenter)
        #expect(before.uploadBadges[uploading.item.uid] == .uploading(step: 4))

        let count = published
        presenter.setBackupPaused(true)
        let paused = presenter.current
        #expect(published == count + 1, "visible tiles update at once")
        #expect(paused.revision != before.revision)
        #expect(paused.membershipRevision == before.membershipRevision)
        #expect(paused.snapshot == before.snapshot, "the library does not reload")
        #expect(paused.uploadBadges[waiting.item.uid] == .paused)
        #expect(paused.uploadBadges[uploading.item.uid] == .paused)
        #expect(paused.uploadBadges[failed.item.uid] == .attention)

        presenter.setBackupPaused(true)
        #expect(published == count + 1, "an unchanged pause publishes nothing")

        // A progress tick and a new photo while paused keep the pause.
        presenter.setPending(pending(tiles, membership: 1, progress: [uploading.item.uid: 6]), enabled: true)
        #expect(presenter.current.uploadBadges[uploading.item.uid] == .paused)
        let added = tile("n", second: 13)
        presenter.setPending(
            pending(tiles + [added], membership: 2, progress: [uploading.item.uid: 6]), enabled: true)
        let grown = await settle(presenter)
        #expect(grown.uploadBadges[added.item.uid] == .paused)

        presenter.setBackupPaused(false)
        let resumed = presenter.current
        #expect(resumed.membershipRevision == grown.membershipRevision)
        #expect(resumed.uploadBadges[waiting.item.uid] == .waiting)
        #expect(resumed.uploadBadges[uploading.item.uid] == .uploading(step: 6))
        #expect(resumed.uploadBadges[failed.item.uid] == .attention)
    }
}

@MainActor private final class EditPendingHarness {
    let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "p", resource: .primary)
    var key: PendingSourceKey { PendingSourceKey(source) }
    let journal: EditReplacementJournalFileStore
    var recorder: PendingBackupEventRecorder
    var coordinator: PendingBackupCoordinator
    private let directory: URL
    private let queue: UploadBackupSyncQueueManifestStore
    let store: PendingBackupManifestStore
    private let date: Date

    init(
        date: Date, membershipInterval: Duration = .zero,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        self.date = date
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("edit-pending-\(UUID().uuidString)")
        queue = try #require(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        store = try #require(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        journal = try #require(EditReplacementJournalFileStore(accountDataDirectory: directory))
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), replacementJournal: journal,
            now: { date })
        coordinator = PendingBackupCoordinator(
            store: store, queues: [.photoLibraryAsset: queue], metadataProvider: EditPendingMetadata(date: date),
            effects: EditPendingEffects(), recorder: recorder, replacementJournal: journal,
            configuration: .init(
                membershipInterval: membershipInterval, doneLinger: .zero, checkmarkDuration: .seconds(3600)),
            now: { date }, sleep: sleep)
    }

    func rebuild() async {
        await coordinator.close()
        recorder.finish()
        let date = date
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), replacementJournal: journal,
            now: { date })
        coordinator = PendingBackupCoordinator(
            store: store, queues: [.photoLibraryAsset: queue], metadataProvider: EditPendingMetadata(date: date),
            effects: EditPendingEffects(), recorder: recorder, replacementJournal: journal,
            configuration: .init(membershipInterval: .zero, doneLinger: .zero, checkmarkDuration: .seconds(3600)),
            now: { date })
        await coordinator.start()
    }

    func enqueue(revision: Int64, state: UploadBackupSyncQueueState, source: UploadSourceIdentity? = nil) {
        let source = source ?? self.source
        let revision = UploadBackupRevision(rawValue: revision)
        #expect(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source, revision: revision, originalFilename: "p.heic",
                    state: state, updatedAt: date)))
        #expect(
            queue.updateState(
                source: source, revision: revision, state: state, attempts: nil, lastError: nil, updatedAt: date))
    }

    func handoff(revision: Int64, remote: PhotoUID, kind: PendingHandoffKind = .uploaded) {
        #expect(
            recorder.recordHandoff(
                source: source, revision: UploadBackupRevision(rawValue: revision), remote: remote, kind: kind)
                == .recorded)
    }

    func wait(_ predicate: (PendingBackupSnapshot) -> Bool) async -> PendingBackupSnapshot {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let snapshot = await coordinator.currentSnapshot()
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let snapshot = await coordinator.currentSnapshot()
        #expect(predicate(snapshot), "the coordinator must reach the requested phase")
        return snapshot
    }

    func closeStores() {
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        recorder.finish()
        queue.close()
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct EditPendingMetadata: PendingSourceMetadataProviding {
    let date: Date

    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        Dictionary(
            uniqueKeysWithValues: keys.map {
                ($0, PendingPresentationMetadata(captureTime: date, mediaType: "image/heic", displayName: "p.heic"))
            })
    }
}

private struct EditPendingEffects: PendingBackupEffects {
    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool { true }
    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool { true }
    func photosVolumeID() async -> String? { "vol" }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private var nextValue: Date?

    init(_ start: Date) { value = start }

    func advanceAfterNextRead(to date: Date) {
        lock.withLock { nextValue = date }
    }

    var now: Date {
        get {
            lock.withLock {
                let current = value
                if let nextValue {
                    value = nextValue
                    self.nextValue = nil
                }
                return current
            }
        }
        set { lock.withLock { value = newValue } }
    }
}

private actor EditMembershipGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var requested: [Duration] = []

    func wait(_ duration: Duration = .zero) async {
        requested.append(duration)
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Returns once a sleep with a duration in `range` was requested, or after 5 seconds without one.
    func waitForSleep(in range: ClosedRange<Duration>) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !requested.contains(where: range.contains), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
