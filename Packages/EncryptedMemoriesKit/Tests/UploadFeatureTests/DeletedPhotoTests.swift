import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

final class DeletedPhotoTests: XCTestCase {
    private var directory: URL!
    private var journal: EditReplacementJournalFileStore!
    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "deleted-photo")
    private let date = Date(timeIntervalSince1970: 1_720_000_001)
    private let digest = Data(repeating: 1, count: 20)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
    }

    override func tearDownWithError() throws {
        journal = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func descriptor(
        source: UploadSourceIdentity? = nil, revision: UploadBackupRevision? = nil
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source ?? self.source, fileURL: directory.appendingPathComponent("photo.heic"),
            filename: "photo.heic", fileSize: 20, modificationDate: date,
            precomputedSHA1Digest: digest, backupRevision: revision)
    }

    private var contentHash: String { "ch(\(UploadContentSHA1.hexString(digest: digest)))" }

    private func pipeline(_ checker: FakeChecker = FakeChecker()) -> UploadDedupePipeline {
        UploadDedupePipeline(store: FakeIdentityStore(), checker: checker, replacementJournal: journal)
    }

    private func addEarlierUpload() throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "gone"), for: source)
    }

    func testFinalUploadWaitsAndReleasesBothClaimsIncludingOwnDraft() async throws {
        try addEarlierUpload()
        let checker = FakeChecker()
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), checker: checker, currentClientUID: "client", replacementJournal: journal)
        checker.remoteItemsByNameHash["nh(photo.heic)"] = [
            .init(
                nameHash: "nh(photo.heic)", contentHash: contentHash, linkState: .draft, linkID: "draft",
                clientUID: "client")
        ]
        for _ in 0..<2 {
            let result = try await pipeline.resolve(descriptor())
            XCTAssertEqual(result.decision, .awaitDeletionCheck)
            XCTAssertFalse(result.decision.uploadsBytes)
            // A negative control that returns an upload must release it before the next resolve.
            if result.decision.uploadsBytes { await pipeline.uploadDidFail(descriptor()) }
        }
        XCTAssertEqual(checker.contentFindCallCount, 2, "Deletion detection must follow the content pass")
    }

    func testPositiveDeletionOutsideScopeSkipsWithoutQuestion() async throws {
        try addEarlierUpload()
        let checker = FakeChecker()
        checker.remoteItemsByNameHash["nh(photo.heic)"] = [
            .init(nameHash: "nh(photo.heic)", contentHash: contentHash, linkState: .trashed, linkID: "other")
        ]
        let result = try await pipeline(checker).resolve(descriptor())
        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: "other"))
        XCTAssertEqual(checker.contentFindCallCount, 0)
        XCTAssertNil(journal.entry(for: source).deletionCheckStartedAt)
    }

    func testContentUnderAnotherNameProvesLiveEvenAfterKeepDeleted() async throws {
        try addEarlierUpload()
        try journal.keepDeleted(for: source)
        let checker = FakeChecker()
        checker.remoteItemsByContentHash[contentHash] = .init(
            nameHash: "nh(renamed.heic)", contentHash: contentHash, linkState: .active, linkID: "live")
        let result = try await pipeline(checker).resolve(descriptor())
        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "live"))
    }

    func testNeverBackedUpAndWatchedFolderStillUpload() async throws {
        let fresh = try await pipeline().resolve(descriptor())
        XCTAssertEqual(fresh.decision, .upload)
        try addEarlierUpload()
        let file = UploadSourceIdentity(kind: .fileURL, identifier: "fixture-file")
        let folder = try await pipeline().resolve(descriptor(source: file))
        XCTAssertEqual(folder.decision, .upload)
    }

    func testKeepDeletedAndRevisionConsentDoNotDependOnAnEditFlag() async throws {
        try addEarlierUpload()
        let unedited = try await pipeline().resolve(descriptor())
        XCTAssertEqual(unedited.decision, .awaitDeletionCheck)
        try journal.keepDeleted(for: source)
        let kept = try await pipeline().resolve(descriptor())
        XCTAssertEqual(kept.decision, .skip(.deletedRemotely, remoteLinkID: "gone"))
        try journal.backUpAgain(revision: .init(rawValue: 7), for: source)
        let older = try await pipeline().resolve(descriptor(revision: .init(rawValue: 6)))
        XCTAssertEqual(older.decision, .awaitDeletionCheck)
        let same = try await pipeline().resolve(descriptor(revision: .init(rawValue: 7)))
        XCTAssertEqual(same.decision, .upload)
        // Consent covers only the version the person saw.
        let newer = try await pipeline().resolve(descriptor(revision: .init(rawValue: 8)))
        XCTAssertEqual(newer.decision, .awaitDeletionCheck)
    }

    func testCurrentOrRetiredMainRestoreClearsAllDeletionState() async throws {
        for retired in [false, true] {
            try addEarlierUpload()
            if retired { try journal.settle(["gone"], related: [], trashed: true, for: source) }
            try journal.backUpAgain(revision: .init(rawValue: 7), for: source)
            try journal.startDeletionCheck(at: date, for: source)
            let checker = FakeChecker()
            checker.linkVisibilityByID["gone"] = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: nil)
            let result = try await pipeline(checker).resolve(descriptor())
            XCTAssertEqual(result.decision, .upload)
            let entry = journal.entry(for: source)
            XCTAssertNil(entry.keptDeleted)
            XCTAssertNil(entry.backUpAgainRevision)
            XCTAssertNil(entry.deletionCheckStartedAt)
        }
    }

    func testMatchingRetiredRestoreClearsChoiceBeforeItIsAdopted() async throws {
        for keep in [true, false] {
            try addEarlierUpload()
            try journal.settle(["gone"], related: [], trashed: true, for: source)
            if keep {
                try journal.keepDeleted(for: source)
            } else {
                try journal.backUpAgain(revision: .init(rawValue: 7), for: source)
            }
            try journal.startDeletionCheck(at: date, for: source)
            let checker = FakeChecker()
            checker.remoteItemsByNameHash["nh(photo.heic)"] = [
                .init(nameHash: "nh(photo.heic)", contentHash: contentHash, linkState: .active, linkID: "gone")
            ]
            let restored = try await pipeline(checker).resolve(descriptor())
            XCTAssertEqual(restored.decision, .skip(.activeDuplicate, remoteLinkID: "gone"))
            XCTAssertNil(journal.entry(for: source).keptDeleted)
            XCTAssertNil(journal.entry(for: source).backUpAgainRevision)
            XCTAssertNil(journal.entry(for: source).deletionCheckStartedAt)
        }
    }

    func testJournalRoundTripAndLedgerOnlyEntriesPersist() throws {
        let entry = EditReplacementJournalEntry(
            keptDeleted: true, backUpAgainRevision: .init(rawValue: 7), deletionCheckStartedAt: date)
        XCTAssertEqual(
            try JSONDecoder().decode(
                EditReplacementJournalEntry.self,
                from: JSONEncoder().encode(entry)), entry)
        XCTAssertFalse(EditReplacementJournalEntry(keptDeleted: true).isEmpty)
        XCTAssertFalse(EditReplacementJournalEntry(backUpAgainRevision: .init(rawValue: 7)).isEmpty)
        XCTAssertFalse(EditReplacementJournalEntry(deletionCheckStartedAt: date).isEmpty)
        try journal.keepDeleted(for: source)
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertTrue(journal.entry(for: source).keptDeleted == true)
        try journal.backUpAgain(revision: .init(rawValue: 7), for: source)
        try journal.startDeletionCheck(at: date, for: source)
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(journal.entry(for: source).backUpAgainRevision, .init(rawValue: 7))
        XCTAssertEqual(journal.entry(for: source).deletionCheckStartedAt, date)
        // The runner clears the choice on every successful backup path, series included.
        try journal.clearDeletionChoice(for: source)
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertNil(journal.entry(for: source).backUpAgainRevision)
        XCTAssertNil(journal.entry(for: source).deletionCheckStartedAt)
        XCTAssertNil(journal.entry(for: source).keptDeleted)
    }

    func testIssueDecodeKeepsFutureDetailAndRecognizesDeletedElsewhere() throws {
        let future = #"{"kind":"futureDeletionKind","detail":"A future reason","automaticRetryAttempt":2}"#
        let persisted = BackupIssueRecord.storagePrefix + Data(future.utf8).base64EncodedString()
        let decoded = try XCTUnwrap(BackupIssueRecord.decode(persisted))
        XCTAssertEqual(decoded.kind, .unknown)
        XCTAssertEqual(decoded.detail, "A future reason")
        XCTAssertEqual(decoded.automaticRetryAttempt, 2)
        let knownValue =
            "encryptedmemories-backup-issue-v1:"
            + "eyJraW5kIjoiZGVsZXRlZEVsc2V3aGVyZSIsImRldGFpbCI6IlJlbW92ZWQiLCJhdXRvbWF0aWNSZXRyeUF0dGVtcHQiOjB9"
        XCTAssertEqual(BackupIssueRecord.decode(knownValue)?.kind, .deletedElsewhere)
        XCTAssertFalse(BackupIssueKind.deletedElsewhere.isRetryable)
    }

    func testRunnerDefersWithoutSuccessThenParksAndInvalidatesOncePerPass() async throws {
        let clock = BackupTestClock(start: date)
        let trail = SupportEventTrail()
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent("queue"), supportTrail: trail))
        let states = try XCTUnwrap(UploadBackupStateManifestStore(url: directory.appendingPathComponent("states")))
        defer { states.close() }
        let checker = FakeChecker()
        let identities = FakeIdentityStore()
        let pipeline = UploadDedupePipeline(
            store: identities, hasher: FakeHasher(), checker: checker, replacementJournal: journal)
        let uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        let replacement = EditedPhotoReplacement(
            remote: FakeEditReplacementRemote(), albums: FakeAlbumCarryOver(), relations: checker,
            identities: identities, journal: journal)
        let runner = BackupSyncRunner(
            queue: queue, preflight: UploadBackupPreflightIndex(store: states),
            resolver: ScriptedBackupResolver(defaultModified: date), identityResolver: pipeline,
            uploader: uploader, editReplacement: replacement,
            configuration: .init(throttle: .init(baseConcurrency: 1)), clock: clock, now: { clock.now })
        let revision = UploadBackupRevision(date: date)
        for id in ["deleted-photo", "deleted-photo-2"] {
            let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id)
            try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "gone-\(id)"), for: source)
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: source, revision: revision,
                        originalFilename: "\(id).heic", state: .discovered, updatedAt: date)))
        }
        // Queue age cannot count as a deletion check. The first read still defers an hour-old row.
        clock.advance(by: 3_600)
        let firstCheck = clock.now
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(checker.invalidateCallCount, 1)
        let deferred = try XCTUnwrap(queue.entry(for: source, revision: revision))
        XCTAssertEqual(deferred.state, .discovered)
        XCTAssertEqual(deferred.attempts, 0)
        XCTAssertEqual(deferred.updatedAt, firstCheck.addingTimeInterval(120))
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertNil(states.record(for: source, revision: revision))
        XCTAssertEqual(
            trail.export(hashingWith: SupportReportIdentifierHasher()).events.filter {
                $0.kind == .backupRowWaiting
            }.count, 2)
        clock.advance(by: 120)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.updatedAt, firstCheck.addingTimeInterval(600))
        clock.advance(by: 479)
        _ = queue.makeRetryableWorkEligible(updatedAt: clock.now)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.updatedAt, firstCheck.addingTimeInterval(659))
        clock.advance(by: 60)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        let parked = try XCTUnwrap(queue.entry(for: source, revision: revision))
        XCTAssertEqual(parked.state, .failedPermanent)
        XCTAssertEqual(parked.attempts, 0)
        XCTAssertEqual(BackupIssueRecord.decode(parked.lastError)?.kind, .deletedElsewhere)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertNil(states.record(for: source, revision: revision))
        _ = queue.makeRetryableWorkEligible(updatedAt: clock.now)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .failedPermanent)
        XCTAssertEqual(
            trail.export(hashingWith: SupportReportIdentifierHasher()).events.filter {
                $0.kind == .backupRowParked && $0.reason == .deletedElsewhere
            }.count, 2)
        let projector = BackupStatusProjector(queue: queue)
        let generation = UUID()
        await projector.start(generation: generation, context: .init()) { _ in }
        let projected = await projector.projectNow(context: .init(), generation: generation, revision: 1)
        XCTAssertEqual(projected?.status.phase, .needsAttention)
        XCTAssertEqual(projected?.status.backedUp, 0)
        XCTAssertEqual(projected?.status.needsAttentionCount, 2)
        XCTAssertEqual(projected.map { BackupStatusPresentation($0.status).attentionCount }, 2)
        await projector.stop()
        let support = queue.backupSupportSnapshot()
        XCTAssertEqual(support.parkedByReason.first { $0.reason == .deletedElsewhere }?.count, 2)
        queue.close()
    }

    func testNinetySecondRemoteLagSettlesOnTheNextEligibleCheck() async throws {
        let clock = BackupTestClock(start: date)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
        let states = try XCTUnwrap(UploadBackupStateManifestStore(url: directory.appendingPathComponent("states")))
        defer {
            queue.close()
            states.close()
        }
        let checker = FakeChecker()
        let identities = FakeIdentityStore()
        let pipeline = UploadDedupePipeline(
            store: identities, hasher: FakeHasher(), checker: checker, replacementJournal: journal)
        let uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        let resolver = ScriptedBackupResolver(defaultModified: date)
        resolver.setEditRevision(.revision(UploadBackupRevision(date: date)), for: source.identifier)
        let replacement = EditedPhotoReplacement(
            remote: FakeEditReplacementRemote(), albums: FakeAlbumCarryOver(), relations: checker,
            identities: identities, journal: journal)
        let runner = BackupSyncRunner(
            queue: queue, preflight: UploadBackupPreflightIndex(store: states), resolver: resolver,
            identityResolver: pipeline, uploader: uploader, editReplacement: replacement,
            clock: clock, now: { clock.now })
        let revision = UploadBackupRevision(date: date)
        try addEarlierUpload()
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: source, revision: revision,
                    originalFilename: "photo.heic", state: .discovered, updatedAt: date)))
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .discovered)
        let identity = try XCTUnwrap(identities.record(for: source))
        clock.advance(by: 90)
        checker.remoteItemsByNameHash[identity.nameHash] = [
            .init(nameHash: identity.nameHash, contentHash: identity.contentHash, linkState: .active, linkID: "visible")
        ]
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .discovered)
        XCTAssertTrue(uploader.requests.isEmpty)
        clock.advance(by: 30)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .alreadyBackedUp)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertNil(journal.entry(for: source).deletionCheckStartedAt)
    }

    func testBackUpAgainUploadsOnceClearsConsentAndLaterDeletionWaits() async throws {
        let clock = BackupTestClock(start: date)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
        let states = try XCTUnwrap(UploadBackupStateManifestStore(url: directory.appendingPathComponent("states")))
        defer {
            queue.close()
            states.close()
        }
        let checker = FakeChecker()
        let identities = FakeIdentityStore()
        let hasher = FakeHasher()
        let pipeline = UploadDedupePipeline(
            store: identities, hasher: hasher, checker: checker, replacementJournal: journal)
        let uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        let resolver = ScriptedBackupResolver(defaultModified: date)
        resolver.setEditRevision(.revision(UploadBackupRevision(date: date)), for: source.identifier)
        let replacement = EditedPhotoReplacement(
            remote: FakeEditReplacementRemote(), albums: FakeAlbumCarryOver(), relations: checker,
            identities: identities, journal: journal)
        let runner = BackupSyncRunner(
            queue: queue, preflight: UploadBackupPreflightIndex(store: states), resolver: resolver,
            identityResolver: pipeline, uploader: uploader, editReplacement: replacement,
            configuration: .init(throttle: .init(baseConcurrency: 1)), clock: clock, now: { clock.now })
        let revision = UploadBackupRevision(date: date)
        try addEarlierUpload()
        try journal.backUpAgain(revision: revision, for: source)
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: source, revision: revision,
                    originalFilename: "photo.heic", state: .discovered, updatedAt: date)))
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .completed)
        XCTAssertNil(journal.entry(for: source).backUpAgainRevision)
        XCTAssertNil(journal.entry(for: source).deletionCheckStartedAt)
        let nextDate = date.addingTimeInterval(1)
        resolver.setModified(nextDate, for: source.identifier)
        let nextRevision = UploadBackupRevision(date: nextDate)
        let lastLink = try XCTUnwrap(identities.record(for: source)?.remoteLinkID)
        checker.remoteItemsByContentHash.removeAll()
        checker.linkVisibilityByID[lastLink] = RemoteLinkVisibility(isActive: false, mainPhotoLinkID: nil)
        hasher.contentSeeds[URL(fileURLWithPath: source.identifier).path] = "new-bytes-after-deletion"
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: source, revision: nextRevision,
                    originalFilename: "next.heic", state: .discovered, updatedAt: date)))
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(try queue.entry(for: source, revision: nextRevision)?.state, .discovered)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertNil(journal.entry(for: source).backUpAgainRevision)
    }

    private struct RunnerParts {
        let queue: UploadBackupSyncQueueManifestStore
        let states: UploadBackupStateManifestStore
        let resolver: ScriptedBackupResolver
        let uploader: MockUploader
        let runner: BackupSyncRunner
    }

    /// A runner over stores in the test directory, so a second runner can continue with the same queue.
    private func makeRunner(
        journal: EditReplacementJournalFileStore, identities: FakeIdentityStore, checker: FakeChecker
    ) throws -> RunnerParts {
        let clock = BackupTestClock(start: date)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
        let states = try XCTUnwrap(UploadBackupStateManifestStore(url: directory.appendingPathComponent("states")))
        let pipeline = UploadDedupePipeline(
            store: identities, hasher: FakeHasher(), checker: checker, replacementJournal: journal)
        let uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        let resolver = ScriptedBackupResolver(defaultModified: date)
        resolver.setEditRevision(.revision(UploadBackupRevision(date: date)), for: source.identifier)
        let replacement = EditedPhotoReplacement(
            remote: FakeEditReplacementRemote(), albums: FakeAlbumCarryOver(), relations: checker,
            identities: identities, journal: journal)
        let runner = BackupSyncRunner(
            queue: queue, preflight: UploadBackupPreflightIndex(store: states), resolver: resolver,
            identityResolver: pipeline, uploader: uploader, editReplacement: replacement,
            configuration: .init(throttle: .init(baseConcurrency: 1)), clock: clock, now: { clock.now })
        return RunnerParts(queue: queue, states: states, resolver: resolver, uploader: uploader, runner: runner)
    }

    func testAConsentCoversOnlyItsOwnRevision() async throws {
        try addEarlierUpload()
        let consented = UploadBackupRevision(date: date)
        // A consent that a failed write left behind after its backup.
        try journal.backUpAgain(revision: consented, for: source)
        let later = date.addingTimeInterval(30)
        let result = try await pipeline().resolve(
            UploadResourceDescriptor(
                source: source, fileURL: directory.appendingPathComponent("photo.heic"), filename: "photo.heic",
                fileSize: 20, modificationDate: later, precomputedSHA1Digest: digest,
                backupRevision: UploadBackupRevision(date: later)))
        XCTAssertEqual(result.decision, .awaitDeletionCheck, "a later deleted version asks again")
        let same = try await pipeline().resolve(descriptor(revision: consented))
        XCTAssertEqual(same.decision, .upload, "the consented version uploads")
    }

    func testABackupOfANewerRevisionSettlesItsParkedRow() async throws {
        let parts = try makeRunner(journal: journal, identities: FakeIdentityStore(), checker: FakeChecker())
        defer {
            parts.queue.close()
            parts.states.close()
        }
        let queued = UploadBackupRevision(date: date)
        let current = UploadBackupRevision(date: date.addingTimeInterval(60))
        XCTAssertTrue(
            parts.queue.upsert(
                .init(
                    source: source, revision: current, originalFilename: "photo.heic", state: .discovered,
                    updatedAt: date)))
        XCTAssertTrue(
            parts.queue.updateState(
                source: source, revision: current, state: .failedPermanent, attempts: nil,
                lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                updatedAt: date))
        XCTAssertTrue(
            parts.queue.upsert(
                .init(
                    source: source, revision: queued, originalFilename: "photo.heic", state: .discovered,
                    updatedAt: date)))
        // The queued revision runs, but the photo changed meanwhile: the backup holds the parked revision's bytes.
        parts.resolver.setModified(date.addingTimeInterval(60), for: source.identifier)
        _ = await parts.runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(try parts.queue.entry(for: source, revision: queued)?.state, .completed)
        XCTAssertEqual(try parts.queue.entry(for: source, revision: current)?.state, .completed)
    }

    #if DEBUG
        @MainActor
        func testControllerBackUpAgainStartsAPass() async throws {
            let suite = "deletion-controller-pass-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults,
                    runtimeSignals: .wiFiWithMobileDataOff),
                identityResolver: FakeIdentityResolver(), uploader: MockUploader(), replacementJournal: journal)
            XCTAssertTrue(controller.installDeletedElsewhereFixtureForTesting())
            controller.setAccessStateForTesting(.full)
            // A real scan would ask PhotoKit, which waits for an authorization answer on a machine without access.
            controller.replacePassBodyForTesting {}
            let item = try XCTUnwrap(controller.failedItems().first)
            XCTAssertFalse(controller.isSyncing)
            controller.backUpAgain(item)
            XCTAssertTrue(controller.isSyncing)
            XCTAssertNotNil(controller.activeExecutionRunID)
            await controller.shutdown()
        }

        @MainActor
        func testBackUpAgainRefusesARejectedDecisionWithoutStartingAPass() async throws {
            let suite = "deletion-controller-refused-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults,
                    runtimeSignals: .wiFiWithMobileDataOff),
                identityResolver: FakeIdentityResolver(), uploader: MockUploader(), replacementJournal: journal)
            XCTAssertTrue(controller.installDeletedElsewhereFixtureForTesting())
            controller.setAccessStateForTesting(.full)
            controller.replacePassBodyForTesting {}
            let item = try XCTUnwrap(controller.failedItems().first)
            let rejected = BackupFailedItem(
                id: item.id, filename: item.filename, reason: item.reason, isPermanent: item.isPermanent,
                issue: .remoteDraftStale, source: item.source, revision: item.revision)
            XCTAssertFalse(controller.backUpAgain(rejected))
            XCTAssertFalse(controller.isSyncing)
            XCTAssertNil(controller.activeExecutionRunID)
            XCTAssertEqual(controller.failedItems(), [item])
            XCTAssertTrue(journal.entry(for: try XCTUnwrap(item.source)).isEmpty)
            await controller.shutdown()
        }
    #endif

    @MainActor
    func testPagedProblemListKeepsTheRow250DecisionAndItsOtherRows() async throws {
        let suite = "deletion-page-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        defer { queue.close() }
        XCTAssertTrue(
            queue.upsertBatch(
                (0..<1_000).map { index in
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: "page-photo-\(index)"),
                        revision: .init(rawValue: Int64(index)), originalFilename: "photo-\(index).heic",
                        state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date)
                }))
        let session = controller.makeProblemListSession()
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(session.total, 1_000)
        XCTAssertTrue(session.requestNextPage())
        await session.waitUntilIdle()
        let before = session.rows.map(\.id)
        let decision = session.rows[249].item
        let decisionSource = try XCTUnwrap(decision.source)
        controller.keepDeleted(decision)
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(session.total, 999)
        XCTAssertEqual(session.rows.count, 400, "An action keeps the loaded page progress")
        XCTAssertEqual(Array(session.rows.prefix(399)).map(\.id), before.filter { $0 != before[249] })
        XCTAssertTrue(journal.entry(for: decisionSource).keptDeleted == true)
        XCTAssertEqual(
            try queue.entry(for: decisionSource, revision: XCTUnwrap(decision.revision))?.state,
            .skippedRemoteDeletion)
        XCTAssertEqual(try XCTUnwrap(queue.summary()).uploaded, 0)
        while session.rows.count < session.total {
            XCTAssertTrue(session.requestNextPage())
            await session.waitUntilIdle()
        }
        XCTAssertEqual(Set(session.rows.map(\.id)).count, 999)
        XCTAssertFalse(session.rows.contains { $0.item.source == decisionSource })
        await session.shutdown()
        await controller.shutdown()
    }

    #if DEBUG
        @MainActor
        func testCommittedDecisionDisappearsBeforeThePacedRefresh() async throws {
            let suite = "deletion-immediate-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
            XCTAssertTrue(controller.installDeletedElsewhereFixtureForTesting(count: 1_000))
            let session = controller.makeProblemListSession()
            session.requestRefresh()
            await session.waitUntilIdle()
            XCTAssertTrue(session.requestNextPage())
            await session.waitUntilIdle()
            let item = session.rows[249].item
            let committed = session.resolveDecision(item) { controller.keepDeleted(item) }
            XCTAssertTrue(committed)
            XCTAssertEqual(session.rows.count, 399, "A committed row leaves before the paced refresh can run")
            XCTAssertFalse(session.rows.contains { $0.item.id == item.id })
            XCTAssertEqual(session.total, 999)
            XCTAssertTrue(journal.entry(for: try XCTUnwrap(item.source)).keptDeleted == true)
            await session.waitUntilIdle()
            XCTAssertFalse(session.rows.contains { $0.item.id == item.id })
            await session.shutdown()
            await controller.shutdown()
        }
    #endif

    @MainActor
    func testControllerMapsDecisionRowsAndWritesBothChoicesWithoutDismissal() async throws {
        let suite = "deletion-controller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let revision = UploadBackupRevision(date: date)
        func seed() throws -> BackupFailedItem {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: source, revision: revision, originalFilename: "photo.heic", state: .discovered,
                        updatedAt: date)))
            XCTAssertTrue(
                queue.updateState(
                    source: source, revision: revision, state: .failedPermanent, attempts: nil,
                    lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                    updatedAt: date))
            return try XCTUnwrap(controller.failedItems().first)
        }
        let item = try seed()
        XCTAssertEqual(item.issue, .deletedElsewhere)
        XCTAssertTrue(item.isPermanent)
        XCTAssertFalse(item.isRetryable)
        controller.dismissFailedItem(item)
        let stale = BackupFailedItem(
            id: item.id, filename: item.filename, reason: item.reason, isPermanent: true,
            issue: .remoteDraftStale, source: source, revision: revision)
        controller.dismissFailedItem(stale)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .failedPermanent)
        controller.keepDeleted(item)
        XCTAssertTrue(journal.entry(for: source).keptDeleted == true)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .skippedRemoteDeletion)
        XCTAssertTrue(controller.failedItems().isEmpty)
        XCTAssertEqual(queue.summary()!.skippedRemoteDeletions, 1)
        XCTAssertEqual(queue.summary()!.uploaded, 0)
        let again = try seed()
        controller.backUpAgain(again)
        XCTAssertEqual(journal.entry(for: source).backUpAgainRevision, revision)
        XCTAssertNil(journal.entry(for: source).keptDeleted)
        XCTAssertEqual(try queue.entry(for: source, revision: revision)?.state, .discovered)
        XCTAssertNil(try queue.entry(for: source, revision: revision)?.lastError)
        await controller.shutdown()
        queue.close()
    }

    func testB1ReplayReadFaultsPreserveTheIncompleteMarkerAndRows() async throws {
        for route in ["queue-count", "catalog-count", "marker", "page"] {
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("\(route)-queue.sqlite")))
            let catalog = try XCTUnwrap(
                PhotoLibraryCatalogManifestStore(url: directory.appendingPathComponent("\(route)-catalog.sqlite")))
            let state = try XCTUnwrap(
                UploadBackupStateManifestStore(url: directory.appendingPathComponent("\(route)-state.sqlite")))
            defer {
                queue.close()
                catalog.close()
                state.close()
            }
            let info = PhotoBackupAssetInfo(
                localIdentifier: "kept", creationDate: nil, modificationDate: date,
                pixelWidth: 10, pixelHeight: 10, durationSeconds: 0, isLivePhoto: false, isVideo: false,
                resources: [.init(role: .originalPhoto, originalFilename: "photo.jpg", mimeType: "image/jpeg")])
            XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: date)]))
            XCTAssertTrue(queue.setCatalogReplayState(.inProgress))
            let sql =
                route == "queue-count"
                ? "SELECT COUNT(*) FROM backup_sync_queue;"
                : route == "catalog-count"
                    ? "SELECT is_removed, COUNT(*)"
                    : route == "marker"
                        ? "SELECT value FROM backup_sync_queue_info"
                        : "SELECT local_id, cloud_id, creation_date"
            let fault = try SQLiteReadInterrupt(
                in: route == "catalog-count" || route == "page" ? catalog as Any : queue as Any,
                matching: sql)
            defer { fault.stop() }
            let engine = UploadBackupSyncEngine(preflight: .init(store: state), queue: queue)
            do {
                try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
                    catalogStore: catalog, queueStore: queue, engine: engine)
                XCTFail("An unknown \(route) must stop replay")
            } catch {
                XCTAssertEqual(error as? UploadError, .backend(L10n.string("backup.error_local_state_unavailable")))
            }
            XCTAssertTrue(fault.fired, route)
            XCTAssertEqual(queue.catalogReplayState(), .inProgress, route)
            XCTAssertEqual(queue.count(), 0, route)
        }
    }

    #if DEBUG
        @MainActor
        func testB1UnknownDismissalReasonKeepsTheDecisionRow() async throws {
            let suite = "dismissal-unknown-reason-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
            let queue = try XCTUnwrap(controller.queueStoreForTesting)
            let row = UploadBackupSyncQueueEntry(
                source: source, revision: UploadBackupRevision(date: date), originalFilename: "photo.heic",
                state: .failedPermanent,
                lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                updatedAt: date)
            XCTAssertTrue(queue.upsert(row))
            let stale = BackupFailedItem(
                id: "stale", filename: "photo.heic", reason: "stale", isPermanent: true,
                issue: .remoteDraftStale, source: source, revision: row.revision)
            let fault = try SQLiteReadInterrupt(in: queue, matching: "SELECT original_filename, byte_count, state")
            defer { fault.stop() }
            controller.dismissFailedItem(stale)
            XCTAssertTrue(fault.fired)
            XCTAssertEqual(
                try queue.entry(for: row.source, revision: row.revision), row,
                "An unknown reason must not dismiss a deletion decision")
            await controller.shutdown()
        }
    #endif

    @MainActor
    func testB1PartialRevisionReadStopsRemoteDeletionDecision() async throws {
        try await assertRemoteDecisionReadFailure(
            matching: "SELECT source_kind, source_id, resource, revision_us, state", afterRows: 2)
    }

    @MainActor
    func testB1UnknownRevisionReasonStopsRemoteDeletionDecision() async throws {
        try await assertRemoteDecisionReadFailure(
            matching: "SELECT original_filename, byte_count, state", occurrence: 4)
    }

    @MainActor
    private func assertRemoteDecisionReadFailure(
        matching: String, occurrence: Int = 1, afterRows: Int = 0
    ) async throws {
        let suite = "deletion-partial-revisions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
        let queue = try XCTUnwrap(
            Mirror(reflecting: controller).children.first(where: { $0.label == "queueStore" })?.value
                as? UploadBackupSyncQueueManifestStore)
        let observer = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        defer { observer.close() }
        let rows = [date, date.addingTimeInterval(60), date.addingTimeInterval(120)].map { timestamp in
            UploadBackupSyncQueueEntry(
                source: source, revision: UploadBackupRevision(date: timestamp), originalFilename: "photo.heic",
                state: .failedPermanent,
                lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                updatedAt: date)
        }
        for row in rows { XCTAssertTrue(queue.upsert(row)) }
        let olderItem = try XCTUnwrap(controller.failedItems().first { $0.revision == rows[0].revision })
        let beforeJournal = journal.entry(for: source)
        let fault = try SQLiteReadInterrupt(
            in: queue, matching: matching, occurrence: occurrence, afterRows: afterRows)
        defer { fault.stop() }

        controller.backUpAgain(olderItem)

        XCTAssertTrue(fault.fired, "The bulk statement must actually be interrupted")
        XCTAssertEqual(fault.tracedRows, afterRows, "The requested SQL fault must fire before any decision effects")
        XCTAssertTrue(queue.isOperational(), "The transient interrupt is forgotten once the database answers")
        XCTAssertEqual(
            journal.entry(for: source), beforeJournal,
            "An incomplete inventory must not choose the clicked older revision")
        for row in rows {
            XCTAssertEqual(
                try observer.entry(for: row.source, revision: row.revision), row,
                "An incomplete revision read must preserve the queue row and its existing reason")
        }
        await controller.shutdown()
    }

    func testB1BulkFaultControlsProveStrictUnknown() throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("bulk-control.sqlite")))
        defer { queue.close() }
        let revisions = [date, date.addingTimeInterval(60), date.addingTimeInterval(120)].map {
            UploadBackupRevision(date: $0)
        }
        for revision in revisions {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: source, revision: revision, originalFilename: "photo.heic", state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date)))
        }
        let fault = try SQLiteReadInterrupt(
            in: queue, matching: "SELECT source_kind, source_id, resource, revision_us, state", afterRows: 2)
        defer { fault.stop() }
        XCTAssertThrowsError(try queue.decisionRows(kind: source.kind, identifiers: [source.identifier])) {
            XCTAssertTrue($0 is SQLiteStoreUnknownReadError)
        }
        XCTAssertTrue(fault.fired)
        XCTAssertEqual(fault.tracedRows, 2)
        XCTAssertTrue(queue.isOperational(), "The transient interrupt is forgotten once the database answers")
    }

    // MARK: One decision writes all of its revisions or none (#1004)

    /// The second sibling write fails once. The fault counts statements, so the result does not depend on the order
    /// of the revisions or on timing; every run must give the same answer.
    #if DEBUG
        @MainActor
        func testAFailedSiblingWriteChangesNoRevisionAndRestoresTheChoice() async throws {
            for keepDeleted in [false, true] {
                for run in 0..<20 {
                    let label = "\(keepDeleted ? "keep" : "again")-\(run)"
                    let result = try await decideWithSiblingWriteFault(
                        keepDeleted: keepDeleted, failingWrite: 2, name: label)
                    XCTAssertTrue(result.fired, "\(label): the second sibling write must actually fail")
                    XCTAssertFalse(result.decided, label)
                    XCTAssertEqual(
                        result.rowsAfter, result.rowsBefore.map(Optional.some),
                        "\(label): a failed decision must leave every revision and its reason unchanged")
                    XCTAssertEqual(result.restoreAttempts, 1, label)
                    XCTAssertEqual(result.journalAfter, result.journalBefore, "\(label): the earlier choice returns")
                    XCTAssertEqual(
                        result.reloadedJournal, result.journalBefore, "\(label): the restored choice is on disk")
                    XCTAssertNotEqual(result.reloadedJournal.keptDeleted, true, label)
                    XCTAssertEqual(result.message, L10n.string("backup.error_local_state_unavailable"), label)
                    XCTAssertFalse(result.lines.contains { $0.hasPrefix("decision.") }, label)
                }
            }
        }
    #endif

    /// When the earlier choice cannot be written back either, the decision still reports no change and the log
    /// names only the kind of choice.
    #if DEBUG
        @MainActor
        func testAFailedRestoreAfterAFailedSiblingWriteStillReportsNoChange() async throws {
            for keepDeleted in [false, true] {
                let label = keepDeleted ? "refused-keep" : "refused-again"
                let result = try await decideWithSiblingWriteFault(
                    keepDeleted: keepDeleted, failingWrite: 2, refusesRestore: true, name: label)
                XCTAssertTrue(result.fired, label)
                XCTAssertFalse(result.decided, "\(label): no silent success")
                XCTAssertEqual(result.rowsAfter, result.rowsBefore.map(Optional.some), label)
                XCTAssertEqual(result.restoreAttempts, 1, label)
                XCTAssertEqual(result.message, L10n.string("backup.error_local_state_unavailable"), label)
                XCTAssertEqual(
                    result.lines.filter { $0.hasPrefix("decision.") },
                    ["decision.choiceNotRestored choice=\(keepDeleted ? "keepDeleted" : "backUpAgain")"], label)
                for line in result.lines {
                    XCTAssertFalse(line.contains(source.identifier), label)
                    XCTAssertFalse(line.contains(directory.path), label)
                    XCTAssertFalse(line.contains("photo.heic"), label)
                }
                // The limit: a choice that the journal cannot take back stays until the person decides again.
                if keepDeleted {
                    XCTAssertEqual(result.journalAfter.keptDeleted, true, label)
                } else {
                    XCTAssertEqual(result.journalAfter.backUpAgainRevision, result.rowsBefore.last?.revision, label)
                }
            }
        }
    #endif

    #if DEBUG
        @MainActor
        func testAHealthyDecisionWritesEveryRevisionWithoutRestoring() async throws {
            for keepDeleted in [false, true] {
                let label = keepDeleted ? "healthy-keep" : "healthy-again"
                let result = try await decideWithSiblingWriteFault(
                    keepDeleted: keepDeleted, failingWrite: nil, name: label)
                XCTAssertTrue(result.decided, label)
                XCTAssertEqual(result.restoreAttempts, 0, label)
                XCTAssertEqual(
                    result.rowsAfter.map { $0?.state },
                    keepDeleted
                        ? [.skippedRemoteDeletion, .skippedRemoteDeletion, .skippedRemoteDeletion]
                        : [.dismissedFailure, .dismissedFailure, .discovered], label)
                if keepDeleted {
                    XCTAssertEqual(result.reloadedJournal.keptDeleted, true, label)
                    XCTAssertNil(result.reloadedJournal.backUpAgainRevision, label)
                } else {
                    XCTAssertNil(result.reloadedJournal.keptDeleted, label)
                    XCTAssertEqual(result.reloadedJournal.backUpAgainRevision, result.rowsBefore.last?.revision, label)
                }
                XCTAssertNil(result.message, label)
                XCTAssertFalse(result.lines.contains { $0.hasPrefix("decision.") }, label)
            }
        }
    #endif

    /// The journal saves the choice, then its compaction fails: the saved choice is the decision, so the queue
    /// writes follow and nothing reports a failure while `keptDeleted` stays on disk.
    #if DEBUG
        @MainActor
        func testACompactionFailureAfterTheSavedChoiceStillCompletesTheDecision() async throws {
            for keepDeleted in [true, false] {
                let label = keepDeleted ? "compaction-keep" : "compaction-again"
                let result = try await decideWithSiblingWriteFault(
                    keepDeleted: keepDeleted, failingWrite: nil, name: label, journalLines: 1_000)
                XCTAssertEqual(result.journalLines, 1_001, "\(label): the compaction must actually fail")
                XCTAssertTrue(result.decided, "\(label): a saved choice is the decision")
                if !result.decided {
                    XCTAssertNotEqual(
                        result.reloadedJournal.keptDeleted, true, "\(label): no choice outlives a refusal")
                }
                XCTAssertEqual(
                    result.rowsAfter.map { $0?.state },
                    keepDeleted
                        ? [.skippedRemoteDeletion, .skippedRemoteDeletion, .skippedRemoteDeletion]
                        : [.dismissedFailure, .dismissedFailure, .discovered], label)
                XCTAssertEqual(
                    result.reloadedJournal.deletionChoice,
                    keepDeleted ? .keptDeleted : .backUpAgain(result.rowsBefore[2].revision), label)
            }
        }
    #endif

    /// The restore saves the earlier choice, then its compaction fails: the choice is back, so no line may say that
    /// it is not.
    #if DEBUG
        @MainActor
        func testACompactionFailureWhileRestoringStillRestoresWithoutAFailureLine() async throws {
            for keepDeleted in [true, false] {
                let label = keepDeleted ? "restore-compaction-keep" : "restore-compaction-again"
                let result = try await decideWithSiblingWriteFault(
                    keepDeleted: keepDeleted, failingWrite: 2, name: label, journalLines: 999)
                XCTAssertTrue(result.fired, label)
                XCTAssertEqual(result.journalLines, 1_001, "\(label): the restore's compaction must actually fail")
                XCTAssertFalse(result.decided, label)
                XCTAssertEqual(result.rowsAfter, result.rowsBefore.map(Optional.some), label)
                XCTAssertEqual(result.reloadedJournal, result.journalBefore, "\(label): the earlier choice is back")
                XCTAssertFalse(result.lines.contains { $0.hasPrefix("decision.") }, label)
            }
        }
    #endif

    /// The runner clears the choice while the failed queue write runs, for example after it backed up another
    /// revision. The restore must not bring the earlier Keep Deleted back over that newer state.
    #if DEBUG
        @MainActor
        func testARestoreKeepsANewerChoiceWrittenDuringTheFailedQueueWrite() async throws {
            let result = try await decideWithSiblingWriteFault(
                keepDeleted: false, failingWrite: 2, name: "newer-clear",
                seed: { [source] journal, _ in try journal.keepDeleted(for: source) },
                duringFailedWrite: { [source] journal in try? journal.clearDeletionChoice(for: source) })
            XCTAssertTrue(result.fired)
            XCTAssertFalse(result.decided)
            XCTAssertEqual(result.rowsAfter, result.rowsBefore.map(Optional.some))
            XCTAssertEqual(
                result.reloadedJournal.deletionChoice,
                EditReplacementDeletionChoice(keptDeleted: nil, backUpAgainRevision: nil, deletionCheckStartedAt: nil),
                "the newer cleared choice stays")
            XCTAssertFalse(result.lines.contains { $0.hasPrefix("decision.") })
        }
    #endif

    /// Another field of the entry changes while the failed queue write runs: the restore takes back only the choice.
    #if DEBUG
        @MainActor
        func testARestoreKeepsOtherFieldsWrittenDuringTheFailedQueueWrite() async throws {
            let meanwhile = PhotoUID(volumeID: "vol", nodeID: "meanwhile")
            let result = try await decideWithSiblingWriteFault(
                keepDeleted: true, failingWrite: 2, name: "newer-field",
                duringFailedWrite: { [source] journal in try? journal.addSuperseded(meanwhile, for: source) })
            XCTAssertTrue(result.fired)
            XCTAssertFalse(result.decided)
            XCTAssertEqual(result.reloadedJournal.deletionChoice, result.journalBefore.deletionChoice)
            XCTAssertTrue(result.reloadedJournal.superseded.contains(meanwhile), "the newer field stays")
            XCTAssertEqual(
                result.reloadedJournal.superseded.filter { $0 != meanwhile }, result.journalBefore.superseded)
        }
    #endif

    /// An earlier Keep Deleted is the state before the decision, so a failed Back Up Again brings it back.
    #if DEBUG
        @MainActor
        func testAFailedBackUpAgainRestoresAnEarlierKeepDeleted() async throws {
            let result = try await decideWithSiblingWriteFault(
                keepDeleted: false, failingWrite: 2, name: "earlier-keep",
                seed: { [source] journal, _ in
                    try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "gone"), for: source)
                    try journal.keepDeleted(for: source)
                })
            XCTAssertTrue(result.fired)
            XCTAssertFalse(result.decided)
            XCTAssertEqual(result.journalBefore.keptDeleted, true)
            XCTAssertEqual(result.reloadedJournal, result.journalBefore)
            XCTAssertEqual(result.rowsAfter, result.rowsBefore.map(Optional.some))
        }
    #endif

    private struct DecisionWriteRun {
        let decided: Bool
        let fired: Bool
        let rowsBefore: [UploadBackupSyncQueueEntry]
        let rowsAfter: [UploadBackupSyncQueueEntry?]
        let journalBefore: EditReplacementJournalEntry
        let journalAfter: EditReplacementJournalEntry
        let reloadedJournal: EditReplacementJournalEntry
        let restoreAttempts: Int
        let message: String?
        let lines: [String]
        let journalLines: Int
    }

    /// Three parked revisions of one photo, an earlier choice in the real journal file, and the real queue store.
    /// `failingWrite` interrupts that occurrence of the per-revision state write once, nil for none.
    /// `seed` replaces the earlier choice. `duringFailedWrite` runs while the failing queue statement executes.
    /// `journalLines` pads the journal log to that many lines and then makes its folder read-only, so the line that
    /// passes 1,000 lines saves but its compaction fails.
    #if DEBUG
        @MainActor
        private func decideWithSiblingWriteFault(
            keepDeleted: Bool, failingWrite: Int?, refusesRestore: Bool = false, name: String,
            seed: ((EditReplacementJournalFileStore, [UploadBackupRevision]) throws -> Void)? = nil,
            duringFailedWrite: ((EditReplacementJournalFileStore) -> Void)? = nil, journalLines: Int? = nil
        ) async throws -> DecisionWriteRun {
            let account = directory.appendingPathComponent(name)
            let journalDirectory = account.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            let fileJournal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: journalDirectory))
            let journal = RestoreRefusingJournal(inner: fileJournal, refusesRestore: refusesRestore)
            let revisions = [date, date.addingTimeInterval(60), date.addingTimeInterval(120)].map {
                UploadBackupRevision(date: $0)
            }
            if let seed {
                try seed(fileJournal, revisions)
            } else {
                try fileJournal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "gone"), for: source)
                if keepDeleted {
                    try fileJournal.backUpAgain(revision: revisions[0], for: source)
                } else {
                    try fileJournal.startDeletionCheck(at: date, for: source)
                }
            }
            let logURL = journalDirectory.appendingPathComponent(EditReplacementJournalFileStore.logFileName)
            func logLineCount() throws -> Int {
                try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").count
            }
            if let journalLines {
                let padding = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "padding")
                var waits = false
                while try logLineCount() < journalLines {
                    if waits {
                        try fileJournal.clearDeletionCheck(for: padding)
                    } else {
                        try fileJournal.startDeletionCheck(at: date, for: padding)
                    }
                    waits.toggle()
                }
                XCTAssertEqual(try logLineCount(), journalLines, name)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journalDirectory.path)
            }
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journalDirectory.path)
            }
            let suite = "deletion-atomic-\(name)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let lines = RecordedLogLines()
            var configuration = PhotoLibraryBackupController.Configuration(
                accountDataDirectory: account, databasePolicy: .conservative, defaults: defaults)
            configuration.backgroundLog = BackgroundWorkLog { lines.append($1) }
            let controller = PhotoLibraryBackupController(
                configuration: configuration, identityResolver: nil, uploader: MockUploader(),
                replacementJournal: journal)
            let queue = try XCTUnwrap(controller.queueStoreForTesting)
            let observer = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: account.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { observer.close() }
            let rows = revisions.map { revision in
                UploadBackupSyncQueueEntry(
                    source: source, revision: revision, originalFilename: "photo.heic", state: .failedPermanent,
                    lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                    updatedAt: date)
            }
            for row in rows { XCTAssertTrue(queue.upsert(row), name) }
            let item = try XCTUnwrap(controller.failedItems().first { $0.revision == rows[0].revision }, name)
            let journalBefore = journal.entry(for: source)
            let fault = try failingWrite.map {
                try SQLiteReadInterrupt(
                    in: queue, matching: "attempts=COALESCE(?, attempts)", occurrence: $0,
                    onFire: duringFailedWrite.map { body in { body(fileJournal) } })
            }
            let decided = keepDeleted ? controller.keepDeleted(item) : controller.backUpAgain(item)
            fault?.stop()
            let rowsAfter = try rows.map { try observer.entry(for: $0.source, revision: $0.revision) }
            let journalAfter = journal.entry(for: source)
            let message = controller.lastMessage
            await controller.shutdown()
            let journalLinesAfter = try logLineCount()
            let reloaded = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: journalDirectory))
            return DecisionWriteRun(
                decided: decided, fired: fault?.fired ?? false, rowsBefore: rows, rowsAfter: rowsAfter,
                journalBefore: journalBefore, journalAfter: journalAfter, reloadedJournal: reloaded.entry(for: source),
                restoreAttempts: journal.restoreAttempts, message: message, lines: lines.values,
                journalLines: journalLinesAfter)
        }
    #endif

    /// A sibling revision whose stored receipt no longer decodes is unknown, not absent: the decision must not skip
    /// it and choose an older revision (#1004 B2, row 15). The healthy and the single-revision routes are pinned by
    /// testOneChoiceSettlesEveryParkedRevisionOfThePhoto and testControllerMapsDecisionRowsAndWritesBothChoices.
    #if DEBUG
        @MainActor
        func testACorruptSiblingReceiptStopsTheDecisionInsteadOfChoosingAnOlderRevision() async throws {
            for keepDeleted in [false, true] {
                let account = directory.appendingPathComponent("corrupt-receipt-\(keepDeleted)")
                try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
                let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: account))
                let suite = "deletion-corrupt-receipt-\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let controller = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: account, databasePolicy: .conservative, defaults: defaults),
                    identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
                let queue = try XCTUnwrap(controller.queueStoreForTesting)
                let rows = [date, date.addingTimeInterval(60)].map { timestamp in
                    UploadBackupSyncQueueEntry(
                        source: source, revision: UploadBackupRevision(date: timestamp), originalFilename: "photo.heic",
                        state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date)
                }
                for row in rows { XCTAssertTrue(queue.upsert(row)) }
                let olderItem = try XCTUnwrap(controller.failedItems().first { $0.revision == rows[0].revision })
                let url = account.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)
                var handle: OpaquePointer?
                XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
                XCTAssertEqual(
                    sqlite3_exec(
                        handle,
                        "UPDATE backup_sync_queue SET remote_commit_reconciliation=X'7B' "
                            + "WHERE revision_us=\(rows[1].revision.rawValue);", nil, nil, nil),
                    SQLITE_OK)
                sqlite3_close(handle)

                let decided = keepDeleted ? controller.keepDeleted(olderItem) : controller.backUpAgain(olderItem)

                XCTAssertFalse(decided, "an unknown sibling stops the decision")
                XCTAssertTrue(journal.entry(for: source).isEmpty, "no choice for a revision the decision cannot see")
                var observer: OpaquePointer?
                XCTAssertEqual(sqlite3_open(url.path, &observer), SQLITE_OK)
                var stmt: OpaquePointer?
                XCTAssertEqual(
                    sqlite3_prepare_v2(
                        observer, "SELECT state, last_error FROM backup_sync_queue ORDER BY revision_us;", -1, &stmt,
                        nil),
                    SQLITE_OK)
                var states: [String] = []
                var errors: [String?] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    states.append(String(cString: sqlite3_column_text(stmt, 0)))
                    errors.append(sqlite3_column_text(stmt, 1).map { String(cString: $0) })
                }
                sqlite3_finalize(stmt)
                sqlite3_close(observer)
                XCTAssertEqual(states, ["failedPermanent", "failedPermanent"], "no revision changes state")
                XCTAssertEqual(errors, rows.map(\.lastError), "no reason changes")
                await controller.shutdown()
            }
        }
    #endif

    @MainActor
    func testOneChoiceSettlesEveryParkedRevisionOfThePhoto() async throws {
        let suite = "deletion-revisions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let older = UploadBackupRevision(date: date)
        let newer = UploadBackupRevision(date: date.addingTimeInterval(60))
        func park() {
            for revision in [older, newer] {
                XCTAssertTrue(
                    queue.upsert(
                        .init(
                            source: source, revision: revision, originalFilename: "photo.heic", state: .discovered,
                            updatedAt: date)))
                XCTAssertTrue(
                    queue.updateState(
                        source: source, revision: revision, state: .failedPermanent, attempts: nil,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date))
            }
        }
        park()
        let olderItem = try XCTUnwrap(controller.failedItems().first { $0.revision == older })
        controller.keepDeleted(olderItem)
        XCTAssertEqual(try queue.entry(for: source, revision: older)?.state, .skippedRemoteDeletion)
        XCTAssertEqual(try queue.entry(for: source, revision: newer)?.state, .skippedRemoteDeletion)
        XCTAssertTrue(controller.failedItems().isEmpty)

        park()
        let again = try XCTUnwrap(controller.failedItems().first { $0.revision == older })
        controller.backUpAgain(again)
        XCTAssertEqual(journal.entry(for: source).backUpAgainRevision, newer, "consent covers the newest version")
        XCTAssertEqual(try queue.entry(for: source, revision: newer)?.state, .discovered)
        XCTAssertEqual(try queue.entry(for: source, revision: older)?.state, .dismissedFailure)
        XCTAssertTrue(controller.failedItems().filter { $0.issue == .deletedElsewhere }.isEmpty)
        await controller.shutdown()
        queue.close()
    }

    /// Restoring a deleted pending edit is the person's answer: when its earlier upload left the Proton trash for
    /// good, the edit backs up without asking. A photo without an earlier upload records nothing.
    @MainActor
    func testRestoringADeletedEditConsentsToItsBackup() async throws {
        let suite = "deletion-restore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func info(_ id: String) -> PhotoBackupAssetInfo {
            PhotoBackupAssetInfo(
                localIdentifier: id, creationDate: date, modificationDate: date.addingTimeInterval(60),
                pixelWidth: 4032, pixelHeight: 3024, durationSeconds: 0, isLivePhoto: false, isVideo: false,
                resources: [.init(role: .originalPhoto, originalFilename: "\(id).heic", mimeType: "image/heic")])
        }
        let plain = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "plain-photo")
        let catalog = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        for id in [source.identifier, plain.identifier] {
            XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info(id), observedAt: date)]))
        }
        catalog.close()
        try addEarlierUpload()
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: FakeIdentityResolver(), uploader: MockUploader(), replacementJournal: journal)

        let returned = await controller.returnToBackup(identifiers: [source.identifier, plain.identifier])

        XCTAssertTrue(returned)
        let entry = PhotoLibraryCatalogMapper.entry(for: info(source.identifier), observedAt: date)
        let edit = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: entry)))
        XCTAssertEqual(journal.entry(for: source).backUpAgainRevision, edit.snapshot.revision)
        XCTAssertTrue(journal.entry(for: plain).isEmpty, "an unedited photo needs no answer")
        await controller.shutdown()
    }

    /// "Back Up Again" on an excluded photo that was deleted in Apple Photos meanwhile succeeds and queues nothing,
    /// so the restore ends and the entry leaves the excluded list.
    @MainActor
    func testReturningAPhotoDeletedInApplePhotosQueuesNothing() async throws {
        let suite = "deletion-return-gone-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let info = PhotoBackupAssetInfo(
            localIdentifier: source.identifier, creationDate: date, modificationDate: date,
            pixelWidth: 4032, pixelHeight: 3024, durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "photo.heic", mimeType: "image/heic")])
        let catalog = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: date)]))
        XCTAssertTrue(catalog.markRemoved([source.identifier], removedAt: date.addingTimeInterval(60)).succeeded)
        catalog.close()
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: FakeIdentityResolver(), uploader: MockUploader(), replacementJournal: journal)

        let returned = await controller.returnToBackup(identifiers: [source.identifier])

        XCTAssertTrue(returned, "a photo that is gone needs nothing, so the restore completes")
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        defer { queue.close() }
        XCTAssertTrue(try queue.decisionRows(kind: .photoLibraryAsset, identifiers: [source.identifier]).isEmpty)
        XCTAssertFalse(controller.isSyncing)
        await controller.shutdown()
    }

    /// The person deletes a backed-up photo, empties the Proton trash, and restores the photo in the app. The
    /// backup state from before the delete must not settle the restored photo as backed up.
    /// Mutation: drop the `removeRecords` loop in `returnToBackup`; the stale completed record stays.
    @MainActor
    func testRestoringADeletedPhotoForgetsItsBackupStateFromBeforeTheDelete() async throws {
        let suite = "deletion-restore-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let info = PhotoBackupAssetInfo(
            localIdentifier: source.identifier, creationDate: date, modificationDate: date,
            pixelWidth: 4032, pixelHeight: 3024, durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "photo.heic", mimeType: "image/heic")])
        let catalog = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        let entry = PhotoLibraryCatalogMapper.entry(for: info, observedAt: date)
        XCTAssertTrue(catalog.upsertBatch([entry]))
        catalog.close()
        let candidate = try XCTUnwrap(
            PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: entry)))
        let state = try XCTUnwrap(
            UploadBackupStateManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.stateDatabaseFileName)))
        defer { state.close() }
        XCTAssertTrue(
            state.upsert(
                UploadBackupAssetRecord(
                    source: candidate.snapshot.source, revision: candidate.snapshot.revision,
                    resourceCount: candidate.snapshot.resourceCount, pendingResourceCount: 0, updatedAt: date)))
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: FakeIdentityResolver(), uploader: MockUploader(), replacementJournal: journal)

        let returned = await controller.returnToBackup(identifiers: [source.identifier])

        XCTAssertTrue(returned)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        defer { queue.close() }
        let row = try XCTUnwrap(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertNotEqual(
            row.state, .alreadyBackedUp,
            "the duplicate check must verify the photo again instead of trusting the state from before the delete")
        await controller.shutdown()
    }
}

/// The real journal file, with a restore that can refuse, so a test reaches the path where the earlier choice
/// cannot be written back.
private final class RestoreRefusingJournal: EditReplacementJournaling, @unchecked Sendable {
    private let inner: EditReplacementJournalFileStore
    private let refusesRestore: Bool
    private let lock = NSLock()
    private var attempts = 0
    var restoreAttempts: Int { lock.withLock { attempts } }

    init(inner: EditReplacementJournalFileStore, refusesRestore: Bool) {
        self.inner = inner
        self.refusesRestore = refusesRestore
    }

    func restoreDeletionChoice(
        _ previous: EditReplacementDeletionChoice, ifStill written: EditReplacementDeletionChoice,
        for source: UploadSourceIdentity
    ) throws {
        lock.withLock { attempts += 1 }
        if refusesRestore { throw UploadError.backend("refused") }
        try inner.restoreDeletionChoice(previous, ifStill: written, for: source)
    }

    func keepDeleted(for source: UploadSourceIdentity) throws { try inner.keepDeleted(for: source) }
    func backUpAgain(revision: UploadBackupRevision, for source: UploadSourceIdentity) throws {
        try inner.backUpAgain(revision: revision, for: source)
    }
    func startDeletionCheck(at date: Date, for source: UploadSourceIdentity) throws {
        try inner.startDeletionCheck(at: date, for: source)
    }
    func clearDeletionCheck(for source: UploadSourceIdentity) throws { try inner.clearDeletionCheck(for: source) }
    func clearDeletionChoice(for source: UploadSourceIdentity) throws { try inner.clearDeletionChoice(for: source) }
    func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry { inner.entry(for: source) }
    func supersededSourceIdentifiers() -> Set<String> { inner.supersededSourceIdentifiers() }
    func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {
        try inner.addSuperseded(uid, for: source)
    }
    func addRemoteSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {
        try inner.addRemoteSuperseded(uid, for: source)
    }
    func addProven(_ nodeID: String, inherited: [String], for source: UploadSourceIdentity) throws {
        try inner.addProven(nodeID, inherited: inherited, for: source)
    }
    func prepareToRetire(_ relatedByMain: [String: [String]], for source: UploadSourceIdentity) throws {
        try inner.prepareToRetire(relatedByMain, for: source)
    }
    func clearRetireIntent(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        try inner.clearRetireIntent(nodeIDs, for: source)
    }
    func settle(_ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity) throws {
        try inner.settle(nodeIDs, related: related, trashed: trashed, for: source)
    }
    func settleGone(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        try inner.settleGone(nodeIDs, for: source)
    }
    func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws {
        try inner.recordUpload(edited: edited, for: source)
    }
    func unretire(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        try inner.unretire(nodeIDs, for: source)
    }
    func namesAnyLink(_ linkIDs: Set<String>) -> Bool { inner.namesAnyLink(linkIDs) }
}
