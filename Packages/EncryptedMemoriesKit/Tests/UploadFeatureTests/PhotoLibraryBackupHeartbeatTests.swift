import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// The execution-lock heartbeat of a running pass: a lost lock stops the pass, a failed write only waits.
@MainActor
final class PhotoLibraryBackupHeartbeatTests: XCTestCase {
    #if DEBUG
        func testAPassStopsWhenAnotherRunTakesItsLock() async throws {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let passStarted = Flag()
            controller.replacePassBodyForTesting {
                passStarted.set()
                // Waits like a long upload until the pass is stopped.
                let deadline = ContinuousClock.now + .seconds(10)
                while !Task.isCancelled, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            }

            controller.syncNow()
            let running = await waitUntil { passStarted.isSet }
            XCTAssertTrue(running)
            let owner = try XCTUnwrap(fixture.lockStore(now: Date()).currentLock()?.runID)
            let successor = try fixture.lockStore(now: Date().addingTimeInterval(600))
            defer { successor.close() }
            XCTAssertEqual(successor.recoverStaleLocks(olderThan: Date().addingTimeInterval(300)).map(\.runID), [owner])
            XCTAssertTrue(successor.acquire(owner: .background, runID: "successor").didAcquire)

            let stopped = await waitUntil { !controller.isSyncing }
            XCTAssertTrue(stopped, "a pass whose lock another run took must stop")
            XCTAssertEqual(successor.currentLock()?.runID, "successor", "the stopped pass leaves the new owner alone")
            await controller.shutdown()
        }

        func testAPassKeepsRunningWhileItsHeartbeatCannotWriteAndRenewsLater() async throws {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let release = Flag()
            let passStarted = Flag()
            controller.replacePassBodyForTesting {
                passStarted.set()
                let deadline = ContinuousClock.now + .seconds(10)
                while !release.isSet, !Task.isCancelled, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }

            controller.syncNow()
            let running = await waitUntil { passStarted.isSet }
            XCTAssertTrue(running)
            let observer = try fixture.lockStore(now: Date())
            defer { observer.close() }
            var writer: OpaquePointer?
            XCTAssertEqual(sqlite3_open(fixture.lockURL.path, &writer), SQLITE_OK)
            defer { sqlite3_close(writer) }
            XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            // Read after the write lock is held, so no heartbeat can move the row in between.
            let started = try XCTUnwrap(observer.currentLock())

            // Several heartbeats fail to write while another connection holds the write lock.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(controller.isSyncing, "a heartbeat that cannot write must not stop the pass")
            XCTAssertEqual(observer.currentLock()?.heartbeatAt, started.heartbeatAt)
            XCTAssertEqual(sqlite3_exec(writer, "COMMIT;", nil, nil, nil), SQLITE_OK)

            let renewed = await waitUntil {
                (observer.currentLock()?.heartbeatAt ?? .distantPast) > started.heartbeatAt
            }
            XCTAssertTrue(renewed, "the next interval renews the lock")
            XCTAssertEqual(observer.currentLock()?.runID, started.runID)
            XCTAssertTrue(controller.isSyncing)
            release.set()
            let finished = await waitUntil { !controller.isSyncing }
            XCTAssertTrue(finished)
            await controller.shutdown()
        }

        private struct Fixture {
            let controller: PhotoLibraryBackupController
            let directory: URL
            let defaults: UserDefaults
            let suite: String
            let lockURL: URL

            func lockStore(now: Date) throws -> BackupExecutionLockManifestStore {
                try XCTUnwrap(BackupExecutionLockManifestStore(url: lockURL, now: { now }))
            }

            func cleanup() {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
        }

        private func makeFixture() throws -> Fixture {
            let suite = "backup-heartbeat-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            var configuration = PhotoLibraryBackupController.Configuration(
                accountDataDirectory: directory,
                // No busy wait: a heartbeat that meets another writer fails at once.
                databasePolicy: LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0),
                defaults: defaults, runtimeSignals: .wiFiWithMobileDataOff)
            configuration.heartbeatInterval = 0.02
            let controller = PhotoLibraryBackupController(
                configuration: configuration, identityResolver: FakeIdentityResolver(), uploader: MockUploader())
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            return Fixture(
                controller: controller, directory: directory, defaults: defaults, suite: suite,
                lockURL: directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName))
        }

        private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while !condition() {
                guard ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }

        private final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.withLock { value } }
            func set() { lock.withLock { value = true } }
        }
    #endif
}
