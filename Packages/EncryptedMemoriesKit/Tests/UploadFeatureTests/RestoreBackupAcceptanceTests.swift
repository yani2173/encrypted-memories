import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Account stores, duplicate checks, queue draining and the session's private effects run unchanged.
/// Local resource export and Proton responses use the existing file-backed runner and server fixtures.
#if DEBUG
    @MainActor
    final class RestoreBackupAcceptanceTests: XCTestCase {
        func testPhotoReturnsThroughProductionSessionWithoutASecondUpload() async throws {
            try await assertRestore(.photo)
        }

        func testVideoReturnsThroughProductionSessionWithoutASecondUpload() async throws {
            try await assertRestore(.video)
        }

        func testLivePhotoReturnsThroughProductionSessionWithoutASecondUpload() async throws {
            try await assertRestore(.live)
        }

        private func assertRestore(_ shape: Fixture.Shape) async throws {
            try await withFixture(shape) { fixture in
                let main = try await fixture.backUp()
                try fixture.exclude(main)
                try await fixture.startSession(main)
                await assertEventually { fixture.session.excludedTiles.map(\.key) == [fixture.key] }
                let uploads = fixture.server.uploadRequestCount
                let reads = fixture.resolver.readCount

                // Freeze fake time so the freshly registered recheck date can be asserted before its timer runs it.
                fixture.clockGate.hold()
                let result = try await fixture.restore(main)

                XCTAssertTrue(result.isReadable)
                guard case .waiting? = result.outcomes[fixture.key] else {
                    return XCTFail("The production effects must enqueue a real compound recheck")
                }
                XCTAssertEqual(
                    PendingBackupCoordinator.defaultRestoreRecheckDelays, [60, 300, 900],
                    "Restore rechecks must keep the production backoff schedule")
                XCTAssertEqual(
                    try XCTUnwrap(fixture.pending.nextEffectDate()).timeIntervalSince(fixture.clock.now), 60,
                    accuracy: 0.001,
                    "The first recheck must register 60 seconds ahead on the injected production schedule")
                let admitted = try XCTUnwrap(fixture.queue.entry(for: fixture.source, revision: fixture.revision))
                XCTAssertFalse(admitted.state.isTerminalSuccess, "The old completed queue row must reopen")
                XCTAssertTrue(try XCTUnwrap(fixture.pending.sourceState(for: fixture.key)).needsQueueSync)
                await assertEventually { fixture.session.excludedTiles.isEmpty }

                // The recheck timer must stay parked while the queue drains. A released timer runs its
                // reconcile on fake time at once, so its restore recheck can re-admit the queue row
                // between the runner's passes and give one restored revision a second resolver read.
                // Draining under the held gate puts the drain wholly before the recheck.
                await fixture.drain()
                XCTAssertTrue(
                    try XCTUnwrap(fixture.queue.entry(for: fixture.source, revision: fixture.revision)).state
                        .isTerminalSuccess)
                fixture.clockGate.release()
                // The recheck ran and the queue is idle before the resolver reads are counted: the parked
                // timer resumes with the drain finished, so its reconcile sees the completed row and can
                // neither re-admit it nor start a second queue pass.
                await assertEventually { fixture.pending.sourceStateRead(for: fixture.key) == .readable(nil) }
                XCTAssertEqual(fixture.resolver.readCount, reads + 1, "One restored revision needs one queue drain")
                XCTAssertEqual(
                    fixture.server.uploadRequestCount, uploads, "The real duplicate check must reuse Proton data")
                XCTAssertEqual(
                    fixture.remote.compensations, 0, "A confirmed Restore must not send another remote Restore")

                let completed = try fixture.queue.entry(for: fixture.source, revision: fixture.revision)
                let repeated = try await fixture.restore(main)
                XCTAssertTrue(repeated.isReadable)
                await fixture.drain()
                XCTAssertEqual(try fixture.queue.entry(for: fixture.source, revision: fixture.revision), completed)
                XCTAssertEqual(fixture.resolver.readCount, reads + 1)
                XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.remote.compensations, 0)
                XCTAssertEqual(
                    try fixture.queue.decisionRows(kind: .photoLibraryAsset, identifiers: [fixture.key.identifier])
                        .count, 1
                )
                XCTAssertEqual(fixture.remote.personRestores, 2)
                XCTAssertEqual(fixture.server.links.filter { $0.state == .active }.count, shape == .live ? 2 : 1)
            }
        }

        func testUnreadableSavedSourceStaysVisiblyExcludedWithoutQueueOrRemoteEffects() async throws {
            try await withFixture(.photo) { fixture in
                let main = try await fixture.backUp()
                try fixture.exclude(main)
                try await fixture.startSession(main)
                await assertEventually { fixture.session.excludedTiles.map(\.key) == [fixture.key] }
                try fixture.execute("UPDATE source_state SET desired='future-state';")
                XCTAssertEqual(fixture.pending.sourceStateRead(for: fixture.key), .unreadable)
                let saved = try fixture.rawSourceRow()
                let queue = try fixture.queue.entry(for: fixture.source, revision: fixture.revision)
                let uploads = fixture.server.uploadRequestCount
                let reads = fixture.resolver.readCount

                let result = try await fixture.restore(main)

                XCTAssertFalse(result.isReadable)
                XCTAssertEqual(result.outcomes[fixture.key], .unreadable)
                XCTAssertEqual(fixture.session.excludedTiles.map(\.key), [fixture.key])
                XCTAssertEqual(try fixture.rawSourceRow(), saved, "Unreadable state must remain byte-for-byte intact")
                XCTAssertEqual(try fixture.queue.entry(for: fixture.source, revision: fixture.revision), queue)
                XCTAssertEqual(fixture.resolver.readCount, reads)
                XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.remote.trashes, 0)
                XCTAssertEqual(fixture.remote.compensations, 0)
                XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
            }
        }

        func testTrashAlreadyInFlightAfterConfirmedRestoreStillOwesCompensation() async throws {
            try await withFixture(.photo) { fixture in
                let main = try await fixture.backUp()
                try fixture.exclude(main, trashInFlight: true)
                await fixture.remote.trashGate.hold()
                try await fixture.startSession(main, waitForExcluded: false)
                await assertEventually { fixture.remote.trashEntered }
                let uploads = fixture.server.uploadRequestCount
                let reads = fixture.resolver.readCount

                _ = try await fixture.restore(main)
                XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
                let restored = try XCTUnwrap(fixture.pending.sourceState(for: fixture.key))
                XCTAssertEqual(restored.desired, .included)
                XCTAssertTrue(restored.needsQueueSync, "The held trash cannot count as a completed Restore")
                await fixture.remote.trashGate.release()

                await assertEventually { fixture.remote.trashes == 1 && fixture.remote.compensations == 1 }
                XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
                XCTAssertTrue(try XCTUnwrap(fixture.pending.sourceState(for: fixture.key)).needsQueueSync)
                XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
                // Reconcile can admit the real queue after compensation. Wait for that admission before draining it.
                await assertEventually {
                    queueEntryForTesting(in: fixture.queue, source: fixture.source, revision: fixture.revision)?.state
                        .isTerminalSuccess == false
                }
                await fixture.drain()
                XCTAssertEqual(fixture.resolver.readCount, reads + 1)
                // The trash check uses the first recheck. Admission after compensation uses the second one.
                // Those sleeps park on the fake clock, so drive fake time past each registered recheck date.
                try await fixture.runRestoreRechecks {
                    fixture.pending.sourceStateRead(for: fixture.key) == .readable(nil)
                }
                XCTAssertEqual(fixture.remote.compensations, 1)
                XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
            }
        }

        func testRestoreRecheckWaitsTheConfiguredFirstDelayOnTheFakeClock() async throws {
            try await withFixture(.photo) { fixture in
                let main = try await fixture.backUp()
                try fixture.exclude(main)
                // 61 s clears the compound's own real-time 30-second admission floor, so the registered date
                // is exactly the configured delay; 61, not the production 60, proves the seam is live.
                try await fixture.startSession(main, restoreRecheckDelays: [61, 62, 63])
                await assertEventually { fixture.session.excludedTiles.map(\.key) == [fixture.key] }

                fixture.clockGate.hold()
                let result = try await fixture.restore(main)

                XCTAssertTrue(result.isReadable)
                guard case .waiting? = result.outcomes[fixture.key] else {
                    return XCTFail("The production effects must enqueue a real compound recheck")
                }
                XCTAssertEqual(
                    try XCTUnwrap(fixture.pending.nextEffectDate()).timeIntervalSince(fixture.clock.now), 61,
                    accuracy: 0.001,
                    "The first recheck must register at the configured first delay, not at the production one")
                fixture.clockGate.release()
                await assertEventually { fixture.session.excludedTiles.isEmpty }
                await fixture.drain()
                XCTAssertTrue(
                    try XCTUnwrap(fixture.queue.entry(for: fixture.source, revision: fixture.revision)).state
                        .isTerminalSuccess)
                await assertEventually { fixture.pending.sourceStateRead(for: fixture.key) == .readable(nil) }
            }
        }

        /// Opt-in: prove the untouched production path really waits the 60-second recheck on wall-clock time.
        /// Skipped in every default run; set the variable to spend the real minute.
        func testPhotoRecheckWaitsTheRealProductionTimersWhenOptedIn() async throws {
            guard ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_REAL_RESTORE_RECHECKS"] == "1" else {
                throw XCTSkip("Set ENCRYPTED_MEMORIES_REAL_RESTORE_RECHECKS=1 to exercise the real recheck timers")
            }
            try await withFixture(.photo) { fixture in
                let main = try await fixture.backUp()
                try fixture.exclude(main)
                try await fixture.startSession(main, productionTimers: true)
                await assertEventually { fixture.session.excludedTiles.map(\.key) == [fixture.key] }
                let uploads = fixture.server.uploadRequestCount

                let restoreStarted = Date()
                let result = try await fixture.restore(main)

                XCTAssertTrue(result.isReadable)
                guard case .waiting? = result.outcomes[fixture.key] else {
                    return XCTFail("The production effects must enqueue a real compound recheck")
                }
                await assertEventually { fixture.session.excludedTiles.isEmpty }
                await fixture.drain()
                XCTAssertTrue(
                    try XCTUnwrap(fixture.queue.entry(for: fixture.source, revision: fixture.revision)).state
                        .isTerminalSuccess)
                await assertEventually(seconds: 400) {
                    fixture.pending.sourceStateRead(for: fixture.key) == .readable(nil)
                }
                XCTAssertGreaterThanOrEqual(
                    Date().timeIntervalSince(restoreStarted), 55,
                    "The real recheck must wait the production 60-second timer, not an immediate fake advance")
                XCTAssertEqual(
                    fixture.server.uploadRequestCount, uploads, "The real duplicate check must reuse Proton data")
            }
        }

        private func withFixture(_ shape: Fixture.Shape, _ body: @MainActor (Fixture) async throws -> Void) async throws
        {
            let fixture = try Fixture(shape)
            do { try await body(fixture) } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }

        private func assertEventually(
            seconds: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(predicate(), file: file, line: line)
        }

        private final class Resolver: BackupResourceResolving, @unchecked Sendable {
            let resource: BackupResolvedResource
            private let lock = NSLock()
            private var reads = 0
            var readCount: Int { lock.withLock { reads } }
            init(_ resource: BackupResolvedResource) { self.resource = resource }
            func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
                lock.withLock { reads += 1 }
                return resource
            }
        }

        private actor TrashGate {
            private var held = false
            private var continuation: CheckedContinuation<Void, Never>?
            func hold() { held = true }
            func wait() async {
                guard held else { return }
                await withCheckedContinuation { continuation = $0 }
            }
            func release() {
                held = false
                continuation?.resume()
                continuation = nil
            }
        }

        /// The coordinator's fake time. Short sleeps advance the fake clock at once, so publish and checkmark
        /// timers behave exactly like before. Sleeps longer than `autoAdvanceLimit` — the Restore recheck and
        /// backoff timers — park until `advance(by:)` moves fake time past their deadline, so a test drives
        /// the recheck ladder itself. While `hold()` is active every sleep parks, freezing fake time, so a
        /// registered recheck date can be asserted without racing the timer that will run it; `release()`
        /// lets every sleep, parked then and parked later, advance the clock at once.
        private final class GatedBackupClock: @unchecked Sendable {
            private let inner: BackupTestClock
            private let lock = NSLock()
            private var holding = false
            private var gated: [CheckedContinuation<Bool, Never>] = []
            private var deadlineWaiters: [(deadline: Date, continuation: CheckedContinuation<Bool, Never>)] = []
            /// Once a test has released fake time, later long sleeps advance it at once again, like they did
            /// before the deadline parking existed. A timer task may reach its sleep only after `release()`,
            /// and parking it then would freeze the fake clock with nobody left to drive it.
            private var releaseAutoAdvances = false
            /// The largest configured coordinator interval is 2 seconds; Restore recheck delays are 60 and up.
            private static let autoAdvanceLimit: TimeInterval = 5

            init(_ inner: BackupTestClock) { self.inner = inner }

            var now: Date { inner.now }

            func hold() { lock.withLock { holding = true } }

            func release() {
                let parked = lock.withLock {
                    holding = false
                    releaseAutoAdvances = true
                    let parked = gated + deadlineWaiters.map(\.continuation)
                    gated.removeAll()
                    deadlineWaiters.removeAll()
                    return parked
                }
                for waiter in parked { waiter.resume(returning: true) }
            }

            /// Moves fake time forward and wakes every parked long sleep whose deadline has passed. The woken
            /// sleepers do not advance fake time themselves; this call already did it for them.
            func advance(by seconds: TimeInterval) {
                inner.advance(by: seconds)
                let due = lock.withLock {
                    let now = inner.now
                    let due = deadlineWaiters.filter { $0.deadline <= now }.map(\.continuation)
                    deadlineWaiters.removeAll { $0.deadline <= now }
                    return due
                }
                for waiter in due { waiter.resume(returning: false) }
            }

            /// The earliest date at which a long sleep is parked, or nil when none is.
            func earliestParkedDeadline() -> Date? {
                lock.withLock { deadlineWaiters.map(\.deadline).min() }
            }

            func sleep(for seconds: TimeInterval) async throws {
                let advanceAfterWake = await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock { () -> Bool in
                        if holding {
                            gated.append(continuation)
                            return false
                        }
                        if seconds > Self.autoAdvanceLimit, !releaseAutoAdvances {
                            deadlineWaiters.append(
                                (deadline: inner.now.addingTimeInterval(max(0, seconds)), continuation: continuation))
                            return false
                        }
                        return true
                    }
                    if resumeNow { continuation.resume(returning: true) }
                }
                if advanceAfterWake { inner.advance(by: max(0, seconds)) }
            }

            static func seconds(of duration: Duration) -> TimeInterval {
                let components = duration.components
                return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
            }
        }

        private final class Remote: PendingRemoteEffects, @unchecked Sendable {
            let server: EditScenarioServer
            let trashGate = TrashGate()
            private let lock = NSLock()
            private var entered = false
            private var trashCount = 0
            private var compensationCount = 0
            private var personCount = 0
            var trashEntered: Bool { lock.withLock { entered } }
            var trashes: Int { lock.withLock { trashCount } }
            var compensations: Int { lock.withLock { compensationCount } }
            var personRestores: Int { lock.withLock { personCount } }
            init(_ server: EditScenarioServer) { self.server = server }
            func personRestore(_ uids: [PhotoUID]) async throws {
                lock.withLock { personCount += 1 }
                try await server.restoreDuplicates(uids)
            }
            func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
                lock.withLock { entered = true }
                await trashGate.wait()
                do {
                    try await server.trashDuplicates(uids)
                    lock.withLock { trashCount += 1 }
                    return .done
                } catch { return .init(retry: Set(uids)) }
            }
            func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
                lock.withLock { compensationCount += 1 }
                do {
                    try await server.restoreDuplicates(uids)
                    return .done
                } catch { return .init(retry: Set(uids)) }
            }
            func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .permanentFailure }
            func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .permanentFailure }
        }

        @MainActor private final class Fixture {
            enum Shape { case photo, video, live }
            let directory: URL
            let suite: String
            let defaults: UserDefaults
            let server: EditScenarioServer
            let remote: Remote
            let pending: PendingBackupManifestStore
            let identities: UploadIdentityManifestStore
            let state: UploadBackupStateManifestStore
            let catalog: PhotoLibraryCatalogManifestStore
            let controller: PhotoLibraryBackupController
            let runner: BackupSyncRunner
            let tagAdder = SpyTagAdder()
            let resolver: Resolver
            let clock: BackupTestClock
            let clockGate: GatedBackupClock
            var session: PendingGridSession!
            var source: UploadSourceIdentity { resolver.resource.candidate.snapshot.source }
            var revision: UploadBackupRevision { resolver.resource.candidate.snapshot.revision }
            var key: PendingSourceKey { PendingSourceKey(source) }
            #if DEBUG
                var queue: UploadBackupSyncQueueManifestStore { controller.queueStoreForTesting! }
            #endif

            #if DEBUG
                init(_ shape: Shape) throws {
                    suite = "restore-acceptance-\(UUID().uuidString)"
                    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                    directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defaults.set(true, forKey: "photoBackup.enabled.v1")
                    defaults.set(true, forKey: "photoBackup.userPaused.v1")
                    clock = BackupTestClock(start: Date().addingTimeInterval(2))
                    clockGate = GatedBackupClock(clock)
                    server = EditScenarioServer()
                    remote = Remote(server)
                    pending = try XCTUnwrap(
                        PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
                    identities = try XCTUnwrap(
                        UploadIdentityManifestStore(
                            url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
                    let journal = try XCTUnwrap(EditReplacementJournalFileStore.shared(accountDataDirectory: directory))
                    let pipeline = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
                    let replacement = EditedPhotoReplacement(
                        remote: server, albums: server, relations: server, identities: identities, journal: journal)
                    var configuration = PhotoLibraryBackupController.Configuration(
                        accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults)
                    configuration.currentAccessState = { .full }
                    controller = PhotoLibraryBackupController(
                        configuration: configuration, identityResolver: pipeline, uploader: server,
                        tagAdder: tagAdder,
                        editReplacement: replacement, pendingStore: pending, requiresPendingStore: true)
                    state = try XCTUnwrap(
                        UploadBackupStateManifestStore(
                            url: directory.appendingPathComponent(PhotoLibraryBackupController.stateDatabaseFileName)))
                    catalog = try XCTUnwrap(
                        PhotoLibraryCatalogManifestStore(
                            url: directory.appendingPathComponent(PhotoLibraryBackupController.catalogDatabaseFileName))
                    )
                    let date = Date(timeIntervalSince1970: 1_720_000_000)
                    var resources: [PhotoBackupAssetInfo.Resource] = [
                        .init(
                            role: shape == .video ? .originalVideo : .originalPhoto,
                            originalFilename: shape == .video ? "MAIN.MOV" : "MAIN.HEIC",
                            mimeType: shape == .video ? "video/quicktime" : "image/heic")
                    ]
                    if shape == .live {
                        resources.append(
                            .init(role: .pairedVideo, originalFilename: "PAIR.MOV", mimeType: "video/quicktime"))
                    }
                    let info = PhotoBackupAssetInfo(
                        localIdentifier: "restore-acceptance", creationDate: date, modificationDate: date,
                        pixelWidth: 10,
                        pixelHeight: 10, durationSeconds: shape == .photo ? 0 : 1, isLivePhoto: shape == .live,
                        isVideo: shape == .video, resources: resources)
                    let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
                    let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: info))
                    XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date())]))
                    let resourceDirectory = directory
                    func descriptor(
                        _ item: PhotoBackupExportPlan.Item, primary: Bool
                    ) throws -> UploadResourceDescriptor {
                        let url = resourceDirectory.appendingPathComponent(item.uploadFilename)
                        let bytes = Data("restore-acceptance-\(item.uploadFilename)".utf8)
                        try bytes.write(to: url)
                        return UploadResourceDescriptor(
                            source: .init(
                                kind: .photoLibraryAsset, identifier: info.localIdentifier,
                                resource: primary ? .primary : item.sourceResource), fileURL: url,
                            filename: item.uploadFilename, fileSize: Int64(bytes.count), modificationDate: date,
                            precomputedSHA1Digest: try UploadContentSHA1.digest(ofFileAt: url))
                    }
                    resolver = Resolver(
                        BackupResolvedResource(
                            candidate: candidate, descriptor: try descriptor(plan.primary, primary: true),
                            mediaType: plan.primary.mimeType ?? "image/heic", captureDate: date,
                            secondaries: try plan.secondaries.map {
                                BackupSecondaryResource(
                                    descriptor: try descriptor($0, primary: false),
                                    mediaType: $0.mimeType ?? "video/quicktime")
                            }))
                    runner = BackupSyncRunner(
                        queue: controller.queueStoreForTesting!,
                        preflight: UploadBackupPreflightIndex(store: state, now: { [clock] in clock.now }),
                        resolver: resolver,
                        identityResolver: pipeline, uploader: server, tagAdder: tagAdder,
                        configuration: .init(throttle: .init(baseConcurrency: 1)),
                        clock: clock, events: controller.pendingRecorder, now: { [clock] in clock.now })
                }
            #endif

            func backUp() async throws -> PhotoUID {
                let engine = UploadBackupSyncEngine(
                    preflight: UploadBackupPreflightIndex(store: state), queue: queue, exclusions: pending)
                _ = try await engine.enqueueBatch([resolver.resource.candidate])
                await drain()
                XCTAssertTrue(try XCTUnwrap(queue.entry(for: source, revision: revision)).state.isTerminalSuccess)
                XCTAssertEqual(server.uploadRequestCount, 1 + resolver.resource.secondaries.count)
                let main = PhotoUID(
                    volumeID: "vol", nodeID: try XCTUnwrap(identities.record(for: source)?.remoteLinkID))
                XCTAssertEqual(
                    pending.recordHandoff(
                        .init(key: key, revision: revision, remote: main, kind: .uploaded, createdAt: Date())),
                    .recorded)
                return main
            }

            func exclude(_ main: PhotoUID, trashInFlight: Bool = false) throws {
                let excluded = try XCTUnwrap(
                    pending.exclude(
                        [
                            .init(
                                key: key,
                                presentation: .init(
                                    captureTime: Date(), mediaType: resolver.resource.mediaType,
                                    displayName: "Restore acceptance"), remote: main, revision: revision)
                        ], at: Date())?.first)
                server.personTrash(main)
                XCTAssertTrue(pending.completeEffect(.queueSync, for: key, generation: excluded.generation, at: Date()))
                if trashInFlight {
                    XCTAssertEqual(pending.beginRemoteOperation(.remoteTrash, for: [excluded]), [key])
                } else {
                    XCTAssertTrue(
                        pending.completeEffect(
                            .remoteTrash, for: key, generation: excluded.generation, remoteLinkID: main.nodeID,
                            at: Date()))
                }
                XCTAssertTrue(pending.unlistFromTrash([key], at: Date()))
            }

            func startSession(
                _ main: PhotoUID,
                waitForExcluded: Bool = true,
                restoreRecheckDelays: [TimeInterval]? = nil,
                productionTimers: Bool = false
            ) async throws {
                // Production timers use the session's own defaults: the real clock and the real sleep.
                if productionTimers {
                    session = try XCTUnwrap(
                        PendingGridSession(store: pending, photoBackup: controller, remote: remote))
                } else {
                    session = try XCTUnwrap(
                        PendingGridSession(
                            store: pending, photoBackup: controller, remote: remote,
                            restoreRecheckDelays: restoreRecheckDelays,
                            now: { [clockGate] in clockGate.now },
                            sleep: { [clockGate] duration in
                                try await clockGate.sleep(for: GatedBackupClock.seconds(of: duration))
                            }))
                }
                let item = PhotoItem(
                    uid: .init(volumeID: main.volumeID, nodeID: "volume-anchor"), captureTime: Date(),
                    mediaType: "image/heic")
                session.setRemote(TimelineSnapshot(orderedItems: [item]))
                session.start()
                if waitForExcluded {
                    for _ in 0..<500 where session.excludedTiles.isEmpty {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertEqual(session.excludedTiles.map(\.key), [key])
                }
            }

            func restore(_ main: PhotoUID) async throws -> PendingBackupRestoreResult {
                try await remote.personRestore([main])
                return await session.restoreSources(ofRemote: [main])
            }

            func drain() async {
                clock.advance(by: 2)
                _ = await runner.runUntilDrained(mode: .eligibleOnly)
            }

            /// Fires the parked Restore recheck timers on the fake clock. Each round moves fake time past the
            /// recheck date the coordinator registered and lets the woken reconcile run; the loop ends once the
            /// predicate holds or no recheck remains. The trash check and the admission after compensation each
            /// need their own recheck.
            func runRestoreRechecks(until predicate: () -> Bool) async throws {
                for _ in 0..<6 {
                    if predicate() { break }
                    if let next = try pending.nextEffectDate() {
                        clockGate.advance(by: max(1, next.timeIntervalSince(clock.now)))
                    } else {
                        // A reconcile may still be in flight; it registers the next recheck shortly.
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    // A timer that parks after the jump above needs its own deadline jumped to as well:
                    // its parked date was computed from fake time before the jump, so it sits a whole
                    // delay ahead. Without this, extreme scheduler lag can strand it past this budget.
                    if let parked = clockGate.earliestParkedDeadline(), parked > clock.now {
                        clockGate.advance(by: max(1, parked.timeIntervalSince(clock.now)))
                    }
                    for _ in 0..<50 where !predicate() {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                XCTAssertTrue(predicate(), "Driving the Restore recheck ladder must reach the expected source state")
            }

            func execute(_ sql: String) throws {
                var handle: OpaquePointer?
                XCTAssertEqual(
                    sqlite3_open_v2(
                        directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path, &handle,
                        SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
                let db = try XCTUnwrap(handle)
                defer { sqlite3_close(db) }
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }

            func rawSourceRow() throws -> [Data?] {
                var handle: OpaquePointer?
                XCTAssertEqual(
                    sqlite3_open_v2(
                        directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path, &handle,
                        SQLITE_OPEN_READONLY, nil), SQLITE_OK)
                let db = try XCTUnwrap(handle)
                defer { sqlite3_close(db) }
                var statement: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT * FROM source_state;", -1, &statement, nil), SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                return (0..<sqlite3_column_count(statement)).map { column in
                    guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
                    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
                }
            }

            func close() async {
                await remote.trashGate.release()
                clockGate.release()
                await session?.close()
                await runner.stop()
                await controller.shutdown()
                state.close()
                catalog.close()
                identities.close()
                pending.close()
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
#endif
