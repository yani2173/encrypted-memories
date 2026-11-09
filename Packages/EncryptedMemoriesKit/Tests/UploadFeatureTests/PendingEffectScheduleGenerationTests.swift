import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Causal regression evidence for the pending-backup schedule defects of issue #909:
/// 1. A key whose action result could not be saved hides its real next effect date from the reconcile timer.
/// 2. A retained defer write applies to any generation of its key, not only the one it was created for.
///
/// The harness helpers are local copies of the private helpers in `PendingBackupCoordinatorTests`, with distinct
/// names, because that file is owned by #1005/#933. The polling wait is the shared `pollWhileFalse`.
final class PendingEffectScheduleGenerationTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var store: PendingBackupManifestStore!
    private var recorder: PendingBackupEventRecorder!
    private var metadata: EffectScheduleMetadata!
    private var effects: EffectScheduleEffects!
    private var coordinator: PendingBackupCoordinator!
    private let date = Date(timeIntervalSince1970: 1_750_000_000.75)
    private let revision = UploadBackupRevision(rawValue: 9)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-effect-schedule-\(UUID().uuidString)", isDirectory: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        store = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), now: { [date] in date })
        metadata = EffectScheduleMetadata()
        effects = EffectScheduleEffects()
        coordinator = makeCoordinator()
    }

    override func tearDown() async throws {
        await coordinator.close()
        recorder.finish()
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        queue.close()
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(
        clock: ScheduleClock? = nil,
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> PendingBackupCoordinator {
        PendingBackupCoordinator(
            store: store,
            queues: [.photoLibraryAsset: queue],
            metadataProvider: metadata,
            effects: effects,
            recorder: recorder,
            replacementJournal: nil,
            identities: nil,
            relations: nil,
            configuration: .init(
                membershipInterval: .zero,
                progressInterval: .milliseconds(1),
                doneLinger: .milliseconds(20),
                checkmarkDuration: .seconds(60),
                uncheckedAdmissionLimit: 64,
                libraryChangeDelay: .zero,
                unreadableRetryDelay: .seconds(60),
                unreadableRetryLimit: .seconds(30 * 60)
            ),
            now: { [date] in clock?.now ?? date },
            sleep: sleep
        )
    }

    private func key(_ id: String) -> PendingSourceKey {
        PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
    }

    private var storeURL: URL { directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName) }

    /// Restarts the coordinator on the given clock, so the reconcile timer records its waits there.
    private func startClocked(_ clock: ScheduleClock) async throws {
        await coordinator.close()
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        try await pollWhileFalse { !clock.waits.isEmpty }
        try await settle()
        XCTAssertFalse(clock.waits.isEmpty, "a real timer must register before its delay is checked")
    }

    /// An included source that owes a queue sync only after `dueIn` seconds.
    private func includedParked(_ id: String, dueIn: TimeInterval) {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: nil)], at: date))
        XCTAssertNotNil(store.include([key(id)], at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + dueIn)", of: id, at: storeURL))
    }

    /// An excluded source with a Proton photo whose remote trash is owed only after `dueIn` seconds.
    @discardableResult
    private func excludedOwed(_ id: String, nodeID: String, dueIn: TimeInterval) -> PhotoUID {
        let remote = PhotoUID(volumeID: "vol", nodeID: nodeID)
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: remote)], at: date))
        XCTAssertTrue(
            Self.setColumns(
                "needs_queue_sync=0, next_attempt_at=\(date.timeIntervalSince1970 + dueIn)", of: id, at: storeURL))
        return remote
    }

    /// Stores the handoff of an uploaded pending photo, so a favorite action knows its remote.
    @discardableResult
    private func favoriteFixture(_ id: String) -> PhotoUID {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-\(id)")
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key(id), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        return remote
    }

    /// How long exact and negative checks of the recorded waits give a timer task to register.
    private static let settleWindow = Duration.milliseconds(300)

    private func settle() async throws {
        try await Task.sleep(for: Self.settleWindow)
    }

    /// Writes column assignments through a second SQLite connection, outside the store's own connection.
    @discardableResult
    private static func setColumns(_ assignments: String, of id: String, at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "UPDATE source_state SET \(assignments) WHERE source_id='\(id)';", nil, nil, nil)
            == SQLITE_OK && sqlite3_changes(db) == 1
    }

    /// Writes a desired value through a second SQLite connection, so the store's own connection sees an unreadable row.
    private func setDesiredRaw(_ value: String, of id: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "UPDATE source_state SET desired='\(value)' WHERE source_id='\(id)';", nil, nil, nil),
            SQLITE_OK)
        XCTAssertEqual(sqlite3_changes(db), 1)
    }

    // MARK: - Case 1: the hidden effect date of a key with an unsaved action result

    /// Control: an ordinary readable owed source parks the timer at its stored next effect date.
    func testAReadableOwedSourceParksTheReconcileTimerAtItsStoredDate() async throws {
        excludedOwed("healthy", nodeID: "healthy-link", dueIn: 30)
        let clock = ScheduleClock(date)
        defer { clock.releaseAll() }
        try await startClocked(clock)
        XCTAssertEqual(
            clock.waits, [.seconds(30)],
            "a readable owed source parks the timer at its stored next effect date")
    }

    /// Issue #909: a key whose action result cannot be saved keeps its real next effect date, but the timer
    /// ignores it and falls back to the degraded backoff. The real date is +10 seconds and a healthy other key is
    /// readable at +30, so showing the real date would wait 10 seconds, not 30. The failing write is a real
    /// transient interruption (SQLITE_INTERRUPT), so the store itself stays recoverable.
    func testAKeyWithAnUnsavedActionResultShowsItsRealNextEffectDate() async throws {
        includedParked("write", dueIn: 10)
        let remote = favoriteFixture("write")
        XCTAssertTrue(store.setFavoriteIntent(key("write"), favorite: true, at: date))
        excludedOwed("healthy", nodeID: "healthy-link", dueIn: 30)
        let failure = KeyedWriteInterrupt(matching: "DELETE FROM pending_action")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let clock = ScheduleClock(date)
        defer { clock.releaseAll() }
        try await startClocked(clock)

        XCTAssertEqual(failure.count, 1, "the action completion write was interrupted, so its result stays unsaved")
        let connection = try KeyedWriteInterrupt.connection(of: store)
        XCTAssertTrue(connection.failuresAreTransient, "an interruption is a transient failure")
        failure.remove(from: store)
        XCTAssertTrue(store.isOperational(), "after the transient failure the store recovers by itself")
        XCTAssertEqual(effects.favorites, [remote])
        XCTAssertEqual(effects.favoriteValues, [true])
        XCTAssertEqual(store.actions().count, 1, "the completed action result could not be saved")
        XCTAssertEqual(
            store.sourceState(for: key("write"))?.nextAttemptAt,
            date.addingTimeInterval(10),
            "the unsaved key keeps its real next effect date of +10 seconds")
        XCTAssertEqual(
            clock.waits, [.seconds(10)],
            "the timer must use the real next effect date of the key with the unsaved action result")
    }

    /// Control for the test above, otherwise identical without the interruption: the action completes, and the
    /// timer parks at the +10 seconds date of the same key. Only the unsaved write hides that date.
    func testAHealthyActionCompletionKeepsItsEffectDateVisible() async throws {
        includedParked("write", dueIn: 10)
        let remote = favoriteFixture("write")
        XCTAssertTrue(store.setFavoriteIntent(key("write"), favorite: true, at: date))
        excludedOwed("healthy", nodeID: "healthy-link", dueIn: 30)

        let clock = ScheduleClock(date)
        defer { clock.releaseAll() }
        try await startClocked(clock)

        XCTAssertEqual(effects.favorites, [remote])
        XCTAssertEqual(store.actions().count, 0, "the healthy completion saves its action result")
        XCTAssertEqual(
            clock.waits, [.seconds(10)],
            "without an unsaved write the timer uses the real next effect date of the key")
    }

    // MARK: - Case 2: a retained defer delays a later generation of the same key

    /// Issue #909: the retained defer was created for the excluded decision whose remote is `link-write`. Its trash
    /// ran and answered "retry", so the defer write was the only thing left, and that write was interrupted. While
    /// it waits unsaved, a real newer decision lands on the same key (`new-link`, generation +1) and parks its fresh
    /// trash at +600 seconds. The retained defer must not apply to that generation; today it overwrites the fresh
    /// schedule with its own backoff.
    func testARetainedDeferCannotDelayALaterGenerationOfTheSameKey() async throws {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-write")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("write"), presentation: nil, remote: remote)], at: date))
        // The first reconcile owes only the remote trash of that decision.
        XCTAssertTrue(Self.setColumns("needs_queue_sync=0", of: "write", at: storeURL))
        effects.trashRetry = [remote]
        // Control on an unrelated key: its parked trash must stay untouched by everything below.
        excludedOwed("other", nodeID: "other-link", dueIn: 700)
        let otherBefore = try XCTUnwrap(store.sourceState(for: key("other")))
        // Only the defer write is interrupted. The trash itself runs and answers "retry".
        let failure = KeyedWriteInterrupt(matching: "UPDATE source_state SET attempts")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let clock = ScheduleClock(date)
        defer { clock.releaseAll() }
        try await startClocked(clock)

        XCTAssertEqual(failure.count, 1, "the defer write was interrupted, so it stays pending")
        XCTAssertTrue(
            try KeyedWriteInterrupt.connection(of: store).failuresAreTransient,
            "an interruption is a transient failure")
        XCTAssertEqual(clock.waits, [.seconds(60)], "the unsaved defer hides the key from the timer")
        XCTAssertEqual(effects.trashBatches.flatMap { $0 }, [remote], "the trash of that decision ran")
        let original = try XCTUnwrap(store.sourceState(for: key("write")))
        XCTAssertEqual(original.attempts, 0, "the interrupted defer write never raised the attempt count")
        XCTAssertEqual(original.nextAttemptAt, date, "the interrupted defer write never moved the stored date")

        failure.remove(from: store)
        let laterRemote = PhotoUID(volumeID: "vol", nodeID: "new-link")
        let newer = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key("write"), presentation: nil, remote: laterRemote)],
                at: date.addingTimeInterval(1))?.first)
        XCTAssertEqual(newer.generation, original.generation + 1)
        XCTAssertEqual(newer.attempts, 0)
        XCTAssertTrue(
            Self.setColumns(
                "needs_queue_sync=0, next_attempt_at=\(date.timeIntervalSince1970 + 600)",
                of: "write", at: storeURL))

        clock.advance(by: .seconds(60))
        try await pollWhileFalse { clock.waits.count >= 2 }
        try await settle()

        let kept = try XCTUnwrap(store.sourceState(for: key("write")))
        XCTAssertEqual(kept.generation, newer.generation)
        XCTAssertEqual(kept.remote, laterRemote)
        XCTAssertEqual(
            kept.attempts, 0,
            "a retained defer must not apply to a later generation of the same key")
        XCTAssertEqual(
            kept.nextAttemptAt, date.addingTimeInterval(600),
            "the newer decision keeps its own schedule")
        XCTAssertTrue(kept.needsRemoteTrash, "the newer trash stays owed")
        XCTAssertEqual(effects.trashBatches.count, 1, "the newer trash is not due yet, so nothing else ran")
        XCTAssertEqual(
            clock.waits, [.seconds(60), .seconds(540)],
            "the next reconcile follows the newer decision's date, not the retained defer's backoff")

        let otherKept = try XCTUnwrap(store.sourceState(for: key("other")))
        XCTAssertEqual(otherKept.generation, otherBefore.generation)
        XCTAssertEqual(otherKept.attempts, otherBefore.attempts)
        XCTAssertEqual(otherKept.nextAttemptAt, otherBefore.nextAttemptAt)
        XCTAssertEqual(otherKept.remote, otherBefore.remote)
    }

    /// Control: the same retained defer still applies when the row keeps the generation it was created for.
    func testARetainedDeferStillAppliesToItsOwnGeneration() async throws {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-write")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("write"), presentation: nil, remote: remote)], at: date))
        XCTAssertTrue(Self.setColumns("needs_queue_sync=0", of: "write", at: storeURL))
        effects.trashRetry = [remote]
        let failure = KeyedWriteInterrupt(matching: "UPDATE source_state SET attempts")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let clock = ScheduleClock(date)
        defer { clock.releaseAll() }
        try await startClocked(clock)
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(clock.waits, [.seconds(60)])
        XCTAssertEqual(effects.trashBatches.flatMap { $0 }, [remote], "the trash of that decision ran")

        failure.remove(from: store)
        clock.advance(by: .seconds(60))
        try await pollWhileFalse { clock.waits.count >= 2 }
        try await settle()

        let kept = try XCTUnwrap(store.sourceState(for: key("write")))
        XCTAssertEqual(
            kept.attempts, 1,
            "the retained defer still schedules the generation it was created for")
        XCTAssertEqual(
            kept.nextAttemptAt, date.addingTimeInterval(120),
            "the retained defer applies its own backoff to its own generation")
        XCTAssertTrue(kept.needsRemoteTrash, "the trash stays owed for the next due pass")
    }

    /// Issue #909, natural coordinator path: a newer decision arrives through `coordinator.exclude` while a prior
    /// defer for an earlier generation is retained. The newer decision's trash is due at once, but today the
    /// stale defer stamps it first, so the trash waits for the stale defer's backoff.
    func testARetainedDeferDelaysTheNewerDecisionOfItsKeyThroughTheCoordinator() async throws {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-write")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("write"), presentation: nil, remote: remote)], at: date))
        // The first decision owes only its remote trash, due at once.
        XCTAssertTrue(Self.setColumns("needs_queue_sync=0", of: "write", at: storeURL))
        effects.trashRetry = [remote]
        // The trash runs and answers "retry". The subsequent defer write is interrupted (limit = 1), leaving a
        // retained pending write.
        let failure = KeyedWriteInterrupt(matching: "UPDATE source_state SET attempts")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let clock = ScheduleClock(date)
        defer { clock.releaseAll() }
        try await startClocked(clock)

        // Retained defer: trash ran, retry answered, defer write pending.
        XCTAssertEqual(failure.count, 1)
        XCTAssertTrue(
            try KeyedWriteInterrupt.connection(of: store).failuresAreTransient,
            "an interruption is a transient failure")
        XCTAssertEqual(effects.trashBatches.flatMap { $0 }, [remote], "the first decision's trash ran")
        let retained = try XCTUnwrap(store.sourceState(for: key("write")))
        XCTAssertEqual(retained.attempts, 0)
        XCTAssertEqual(retained.nextAttemptAt, date, "the interrupted defer never moved the stored date")
        failure.remove(from: store)
        XCTAssertTrue(store.isOperational(), "after the transient failure the store recovers by itself")

        // The person deletes the photo again: a real newer decision through the public coordinator path.
        let excluded = await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "write")])
        XCTAssertTrue(excluded, "the second delete stores its decision")

        let newer = try XCTUnwrap(store.sourceState(for: key("write")))
        XCTAssertEqual(newer.generation, retained.generation + 1, "the second delete is a newer generation")
        XCTAssertEqual(newer.remote, remote, "the store still knows the photo that the trash owes")

        // RED assertions (correct behavior: the newer decision's due effects run immediately):
        XCTAssertEqual(
            effects.trashBatches.flatMap { $0 }.filter { $0 == remote }.count, 2,
            "the newer decision's trash is due at once, so it must dispatch during the delete")
        XCTAssertFalse(
            newer.needsQueueSync,
            "the newer generation's queue sync runs at once when the stale defer does not block it")
        // Stabilizers that hold in both the fixed and the current broken state (they lock the single-stamp behavior):
        XCTAssertEqual(
            newer.attempts, 1,
            "exactly one defer was applied to the newer generation — the fresh one or the retained one")
        XCTAssertEqual(
            clock.waits.last, .seconds(60),
            "the reconcile timer parks at the +60 seconds backoff (fresh defer or retained defer)")
    }

    // MARK: - deferEffects on absent and unreadable rows

    /// A defer for an absent key has nothing to schedule, so the write is handled and no row is created.
    func testADeferForAnAbsentKeyReportsTheWriteAsHandled() async throws {
        XCTAssertNil(store.sourceState(for: key("absent")))
        XCTAssertTrue(store.deferEffects(for: key("absent"), at: date))
        XCTAssertNil(store.sourceState(for: key("absent")), "a defer does not create a row for an absent key")
    }

    /// A defer for a row the store cannot decode is not handled; the write stays pending.
    func testADeferForAnUnreadableKeyKeepsTheWrite() async throws {
        excludedOwed("bad", nodeID: "bad-link", dueIn: 0)
        try setDesiredRaw("invalid", of: "bad")
        XCTAssertFalse(
            store.deferEffects(for: key("bad"), at: date),
            "an unreadable row cannot take a defer, so the write stays pending")
    }

    // MARK: - Local harness

    /// Advances only when the test requests it. Every registered wait has its own gate.
    private final class ScheduleClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        private var recorded: [Duration] = []
        private var sleeping: [(Date, ScheduleGate)] = []
        var now: Date { lock.withLock { value } }
        var waits: [Duration] { lock.withLock { recorded } }

        init(_ date: Date) { value = date }

        func sleep(_ duration: Duration) async throws {
            let gate = ScheduleGate()
            lock.withLock {
                recorded.append(duration)
                let parts = duration.components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                sleeping.append((value.addingTimeInterval(seconds), gate))
            }
            await gate.wait()
            try Task.checkCancellation()
        }

        func advance(by duration: Duration) {
            let due = lock.withLock { () -> [ScheduleGate] in
                let parts = duration.components
                value = value.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
                let due = sleeping.filter { $0.0 <= value }.map(\.1)
                sleeping.removeAll { $0.0 <= value }
                return due
            }
            due.forEach { $0.open() }
        }

        func releaseAll() {
            let gates = lock.withLock {
                defer { sleeping.removeAll() }
                return sleeping.map(\.1)
            }
            gates.forEach { $0.open() }
        }
    }

    /// Holds every waiter until `open()`; afterwards `wait()` returns at once.
    private final class ScheduleGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }
    }

    /// Transient interruption of writes targeting `fragment`, modeled on KeyedReadFailure.
    /// Uses sqlite3_trace_v2 (SQLITE_TRACE_STMT) and sqlite3_interrupt to produce SQLITE_INTERRUPT.
    /// All recorded failures are transient per SQLiteStoreConnection.transientResultCodes.
    private final class KeyedWriteInterrupt: @unchecked Sendable {
        private let lock = NSLock()
        private var interrupted = 0
        private let fragment: String
        private var armed = false
        private var skip: Int
        private var limit: Int
        var count: Int { lock.withLock { interrupted } }

        /// Lets the first `skip` matching writes pass, then interrupts at most `limit`.
        init(matching fragment: String, skip: Int = 0, limit: Int = 1) {
            self.fragment = fragment
            self.skip = skip
            self.limit = limit
        }

        func install(on store: PendingBackupManifestStore) throws {
            let connection = try Self.connection(of: store)
            connection.withLock {
                _ = sqlite3_trace_v2(
                    connection.database, UInt32(SQLITE_TRACE_STMT),
                    { _, context, pointer, _ in
                        guard let context, let pointer else { return 0 }
                        let statement = OpaquePointer(pointer)
                        let failure = Unmanaged<KeyedWriteInterrupt>.fromOpaque(context).takeUnretainedValue()
                        guard let sql = sqlite3_sql(statement).map({ String(cString: $0) }) else { return 0 }
                        guard sql.contains(failure.fragment) else { return 0 }
                        let doInterrupt = failure.lock.withLock { () -> Bool in
                            guard failure.limit > 0 else { return false }
                            failure.limit -= 1
                            failure.interrupted += 1
                            return true
                        }
                        if doInterrupt { sqlite3_interrupt(sqlite3_db_handle(statement)) }
                        return 0
                    }, Unmanaged.passUnretained(self).toOpaque())
            }
        }

        func remove(from store: PendingBackupManifestStore) {
            guard let connection = try? Self.connection(of: store) else { return }
            connection.withLock { _ = sqlite3_trace_v2(connection.database, 0, nil, nil) }
        }

        static func connection(of store: PendingBackupManifestStore) throws -> SQLiteStoreConnection {
            try XCTUnwrap(
                Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value
                    as? SQLiteStoreConnection)
        }
    }
}

/// Minimal metadata provider: keys without a set value count as not accessible.
private final class EffectScheduleMetadata: PendingSourceMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PendingSourceKey: PendingPresentationMetadata] = [:]

    func set(_ key: PendingSourceKey, _ value: PendingPresentationMetadata) {
        lock.withLock { values[key] = value }
    }

    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        lock.withLock { values.filter { keys.contains($0.key) } }
    }
}

/// Minimal effects double with the observations the schedule tests need.
private final class EffectScheduleEffects: PendingBackupEffects, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [[String]] = []
    private var _trashed: [[PhotoUID]] = []
    private var _favorites: [PhotoUID] = []
    private var _favoriteValues: [Bool] = []
    private var _removeSucceeds = true
    private var _favoriteResult = PendingEffectResult.done
    private var _volumeID: String? = "photos-volume"
    private var _trashRetry = Set<PhotoUID>()

    var removed: [[String]] { lock.withLock { _removed } }
    var trashBatches: [[PhotoUID]] { lock.withLock { _trashed } }
    var favorites: [PhotoUID] { lock.withLock { _favorites } }
    var favoriteValues: [Bool] { lock.withLock { _favoriteValues } }
    var favoriteResult: PendingEffectResult {
        get { lock.withLock { _favoriteResult } }
        set { lock.withLock { _favoriteResult = newValue } }
    }
    /// Photos that the fake Proton trash leaves without an answer.
    var trashRetry: Set<PhotoUID> {
        get { lock.withLock { _trashRetry } }
        set { lock.withLock { _trashRetry = newValue } }
    }

    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
        lock.withLock {
            _removed.append(identifiers.sorted())
            return _removeSucceeds
        }
    }

    func returnToBackup(_ keys: [PendingSourceKey]) async -> Set<PendingSourceKey> {
        Set(keys)
    }

    func returnToBackup(_ states: [PendingSourceState]) async -> [PendingSourceKey: PendingBackupReturnOutcome] {
        lock.withLock {
            if states.isEmpty { return [:] }
            return Dictionary(uniqueKeysWithValues: states.map { ($0.key, .unreadable) })
        }
    }

    func photosVolumeID() async -> String? {
        lock.withLock { _volumeID }
    }

    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        lock.withLock {
            _trashed.append(uids)
            return PendingBatchEffectResult(retry: _trashRetry.intersection(uids))
        }
    }

    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        .done
    }

    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        lock.withLock {
            _favorites.append(uid)
            _favoriteValues.append(favorite)
            return _favoriteResult
        }
    }

    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        lock.withLock { _favoriteResult }
    }
}
