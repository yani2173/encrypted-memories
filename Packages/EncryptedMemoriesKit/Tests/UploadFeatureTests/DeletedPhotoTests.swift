import Foundation
import PhotosCore
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
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.updatedAt, firstCheck.addingTimeInterval(600))
        clock.advance(by: 479)
        _ = queue.makeRetryableWorkEligible(updatedAt: clock.now)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.updatedAt, firstCheck.addingTimeInterval(659))
        clock.advance(by: 60)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        let parked = try XCTUnwrap(queue.entry(for: source, revision: revision))
        XCTAssertEqual(parked.state, .failedPermanent)
        XCTAssertEqual(parked.attempts, 0)
        XCTAssertEqual(BackupIssueRecord.decode(parked.lastError)?.kind, .deletedElsewhere)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertNil(states.record(for: source, revision: revision))
        _ = queue.makeRetryableWorkEligible(updatedAt: clock.now)
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .failedPermanent)
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
        resolver.setEditRevision(.trustedNoContentEdits, for: source.identifier)
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
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .discovered)
        let identity = try XCTUnwrap(identities.record(for: source))
        clock.advance(by: 90)
        checker.remoteItemsByNameHash[identity.nameHash] = [
            .init(nameHash: identity.nameHash, contentHash: identity.contentHash, linkState: .active, linkID: "visible")
        ]
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .discovered)
        XCTAssertTrue(uploader.requests.isEmpty)
        clock.advance(by: 30)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .alreadyBackedUp)
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
        resolver.setEditRevision(.trustedNoContentEdits, for: source.identifier)
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
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .completed)
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
        XCTAssertEqual(queue.entry(for: source, revision: nextRevision)?.state, .discovered)
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
        resolver.setEditRevision(.trustedNoContentEdits, for: source.identifier)
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
        XCTAssertEqual(parts.queue.entry(for: source, revision: queued)?.state, .completed)
        XCTAssertEqual(parts.queue.entry(for: source, revision: current)?.state, .completed)
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
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .failedPermanent)
        controller.keepDeleted(item)
        XCTAssertTrue(journal.entry(for: source).keptDeleted == true)
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .skippedRemoteDeletion)
        XCTAssertTrue(controller.failedItems().isEmpty)
        XCTAssertEqual(queue.summary().skippedRemoteDeletions, 1)
        XCTAssertEqual(queue.summary().uploaded, 0)
        let again = try seed()
        controller.backUpAgain(again)
        XCTAssertEqual(journal.entry(for: source).backUpAgainRevision, revision)
        XCTAssertNil(journal.entry(for: source).keptDeleted)
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .discovered)
        XCTAssertNil(queue.entry(for: source, revision: revision)?.lastError)
        await controller.shutdown()
        queue.close()
    }

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
        XCTAssertEqual(queue.entry(for: source, revision: older)?.state, .skippedRemoteDeletion)
        XCTAssertEqual(queue.entry(for: source, revision: newer)?.state, .skippedRemoteDeletion)
        XCTAssertTrue(controller.failedItems().isEmpty)

        park()
        let again = try XCTUnwrap(controller.failedItems().first { $0.revision == older })
        controller.backUpAgain(again)
        XCTAssertEqual(journal.entry(for: source).backUpAgainRevision, newer, "consent covers the newest version")
        XCTAssertEqual(queue.entry(for: source, revision: newer)?.state, .discovered)
        XCTAssertEqual(queue.entry(for: source, revision: older)?.state, .dismissedFailure)
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
            _ = catalog.upsert(PhotoLibraryCatalogMapper.entry(for: info(id), observedAt: date))
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
        _ = catalog.upsert(PhotoLibraryCatalogMapper.entry(for: info, observedAt: date))
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
        XCTAssertTrue(queue.rows(kind: .photoLibraryAsset, identifiers: [source.identifier]).isEmpty)
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
        _ = catalog.upsert(entry)
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
