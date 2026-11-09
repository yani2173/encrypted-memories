import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class BackupTempFileStoreTests: XCTestCase {
    func testSecondOversizedReservationIsRejected() throws {
        let store = BackupTempFileStore(
            directory: directory, maximumBytes: 10, minimumFreeBytes: 0,
            availableCapacity: { _ in 100 }, now: Date.init)
        let first = try store.reserve(filename: "first", expectedBytes: 30)

        XCTAssertThrowsError(try store.reserve(filename: "second", expectedBytes: 25)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        XCTAssertNoThrow(try store.recordWrite(to: first, byteCount: 30))
    }

    func testStreamedWritePreservesFreeReserveAndAccounting() throws {
        let store = BackupTempFileStore(
            directory: directory, maximumBytes: 50, minimumFreeBytes: 5,
            availableCapacity: { _ in 12 }, now: { Date(timeIntervalSince1970: 1) })
        let partial = try store.reserve(filename: "stream", expectedBytes: 0)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try store.recordWrite(to: partial, byteCount: 3)
        try handle.write(contentsOf: Data(repeating: 1, count: 3))

        XCTAssertThrowsError(try store.recordWrite(to: partial, byteCount: 5)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        XCTAssertEqual(store.usedBytes(), 3)
        XCTAssertNoThrow(try store.recordWrite(to: partial, byteCount: 4))
        try handle.write(contentsOf: Data(repeating: 2, count: 4))
        XCTAssertEqual(store.usedBytes(), 7)
    }

    func testDefaultLimitsMatchPolicy() {
        let policy = DiskCacheBudgetPolicy(platform: .mobile)
        let store = BackupTempFileStore(directory: directory)
        XCTAssertEqual(store.maximumBytes, 2 << 30)
        XCTAssertEqual(store.minimumFreeBytes, 1 << 30)
        XCTAssertEqual(store.maximumBytes, policy.backupMaximumBytes)
        XCTAssertEqual(store.minimumFreeBytes, policy.backupMinimumFreeBytes)
    }

    func testInjectedPolicyBudgetControlsReservations() {
        let store = BackupTempFileStore(
            directory: directory, policyBudget: { _ in (10, 5) },
            availableCapacity: { _ in 100 }, now: Date.init)
        XCTAssertEqual(store.maximumBytes, 10)
        XCTAssertEqual(store.minimumFreeBytes, 5)
        XCTAssertNoThrow(try store.reserve(filename: "first", expectedBytes: 6))
        XCTAssertThrowsError(try store.reserve(filename: "second", expectedBytes: 6)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
    }

    func testExtremeChunkIsRejectedWithoutDisturbingAccounting() throws {
        let store = BackupTempFileStore(
            directory: directory, maximumBytes: 10, minimumFreeBytes: 0,
            availableCapacity: { _ in 100 }, now: Date.init)
        let partial = try store.reserve(filename: "extreme.mov", expectedBytes: 0)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        try store.recordWrite(to: partial, byteCount: 1)
        try handle.write(contentsOf: Data(repeating: 1, count: 1))

        XCTAssertThrowsError(try store.recordWrite(to: partial, byteCount: Int.max)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        XCTAssertEqual(store.usedBytes(), 1, "a rejected chunk must not change the written accounting")
        try store.recordWrite(to: partial, byteCount: 4)
        try handle.write(contentsOf: Data(repeating: 2, count: 4))
        XCTAssertEqual(store.usedBytes(), 5, "a valid chunk after the rejection must succeed")

        try store.recordWrite(to: partial, byteCount: 5)
        try handle.write(contentsOf: Data(repeating: 3, count: 5))
        XCTAssertEqual(store.usedBytes(), 10, "the exact remaining budget is still writable")

        XCTAssertThrowsError(try store.recordWrite(to: partial, byteCount: 1)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        XCTAssertEqual(store.usedBytes(), 10, "a chunk past the budget is rejected")

        try store.recordWrite(to: partial, byteCount: -5)
        XCTAssertEqual(store.usedBytes(), 10, "a negative chunk stays ignored, as before")
    }

    func testExtremeChunkInPoolSharedWithAnotherReservationIsRejected() throws {
        let store = BackupTempFileStore(
            directory: directory, maximumBytes: 10, minimumFreeBytes: 0,
            availableCapacity: { _ in 100 }, now: Date.init)
        _ = try store.reserve(filename: "holder.dat", expectedBytes: 5)
        let partial = try store.reserve(filename: "extreme-shared.mov", expectedBytes: 0)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        XCTAssertThrowsError(try store.recordWrite(to: partial, byteCount: Int.max)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        XCTAssertEqual(store.usedBytes(), 0, "a rejected chunk must not change the written accounting")
        try store.recordWrite(to: partial, byteCount: 5)
        try handle.write(contentsOf: Data(repeating: 1, count: 5))
        XCTAssertEqual(store.usedBytes(), 5, "a valid chunk after the rejection must succeed")
    }

    func testStagedWritesCannotUseMoreThanHalfThePool() throws {
        let store = BackupTempFileStore(
            directory: directory, maximumBytes: 10, minimumFreeBytes: 0,
            availableCapacity: { _ in 100 }, now: Date.init)
        let staged = try store.reserve(filename: "staged", expectedBytes: 0, staging: true)
        try store.recordWrite(to: staged, byteCount: 5)
        XCTAssertThrowsError(try store.recordWrite(to: staged, byteCount: 1)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
    }

    private final class CapacityProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        private var calls = 0

        init(_ value: Int64) { self.value = value }

        func read(_ url: URL) -> Int64? {
            lock.withLock {
                calls += 1
                return value
            }
        }

        var callCount: Int { lock.withLock { calls } }
    }

    private final class TestNow: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_700_000_000)

        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(seconds) }
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-temp-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReserveCommitLifecycle() throws {
        let store = BackupTempFileStore(directory: directory)
        let partial = try store.reserve(filename: "IMG_1.HEIC", expectedBytes: 4)
        XCTAssertTrue(
            partial.lastPathComponent.hasSuffix(".partial"),
            "in-flight exports must be journaled as partial")
        try Data("abcd".utf8).write(to: partial)

        let final = try store.commit(partial)
        XCTAssertFalse(final.lastPathComponent.hasSuffix(".partial"))
        XCTAssertEqual(try Data(contentsOf: final), Data("abcd".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testALargeFileThatCannotFitReportsTheSpaceItNeeds() throws {
        let probe = CapacityProbe(10_000)
        let store = BackupTempFileStore(
            directory: directory, maximumBytes: 1_000, minimumFreeBytes: 500,
            availableCapacity: { probe.read($0) }, now: { Date() })

        XCTAssertNoThrow(try store.ensureFreeSpace(forAdditionalBytes: 9_000))
        XCTAssertThrowsError(try store.ensureFreeSpace(forAdditionalBytes: 20_000)) { error in
            XCTAssertEqual(
                error as? BackupTempFileStore.BackupTempFileError, .needsFreeSpace(requiredBytes: 20_500),
                "the message names the free space the file needs")
        }
        XCTAssertTrue(store.hasFreeSpace(forAdditionalBytes: 9_000))
        XCTAssertFalse(store.hasFreeSpace(forAdditionalBytes: 20_000))
    }

    func testSweepClearsPartialsAndCommittedFiles() throws {
        let store = BackupTempFileStore(directory: directory)
        let partial = try store.reserve(filename: "a.jpg", expectedBytes: 1)
        try Data("x".utf8).write(to: partial)
        let committed = try store.commit(try writeReserved(store, name: "b.jpg"))

        store.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
        XCTAssertEqual(store.usedBytes(), 0)
    }

    func testDiskBudgetIsEnforcedBeforeBytesAreWritten() throws {
        let store = BackupTempFileStore(directory: directory, maximumBytes: 10)
        let first = try store.reserve(filename: "small.jpg", expectedBytes: 6)
        try Data(repeating: 0, count: 6).write(to: first)

        XCTAssertThrowsError(try store.reserve(filename: "big.jpg", expectedBytes: 6)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        // Freeing space unblocks the budget.
        store.discard(first)
        XCTAssertNoThrow(try store.reserve(filename: "big.jpg", expectedBytes: 6))
    }

    func testUnknownPhotoKitSizeIsEnforcedAsChunksArrive() throws {
        let store = BackupTempFileStore(directory: directory, maximumBytes: 10, minimumFreeBytes: 0)
        let partial = try store.reserve(filename: "photo.heic", expectedBytes: 0)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        try store.recordWrite(to: partial, byteCount: 6)
        try handle.write(contentsOf: Data(repeating: 1, count: 6))
        XCTAssertThrowsError(try store.recordWrite(to: partial, byteCount: 5)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        XCTAssertEqual(store.usedBytes(), 6)
    }

    func testFreeCapacityProbeIsSampledInsteadOfCalledForEveryChunk() throws {
        let capacity = CapacityProbe(8 << 30)
        let clock = TestNow()
        let store = BackupTempFileStore(
            directory: directory,
            maximumBytes: 2 << 30,
            minimumFreeBytes: 1 << 30,
            availableCapacity: capacity.read,
            now: { clock.now }
        )
        let partial = try store.reserve(filename: "large.mov", expectedBytes: 0)
        XCTAssertEqual(capacity.callCount, 1)

        for _ in 0..<100 {
            try store.recordWrite(to: partial, byteCount: 64 << 10)
        }
        XCTAssertEqual(capacity.callCount, 1, "small PhotoKit chunks must not issue one volume query each")

        clock.advance(1)
        try store.recordWrite(to: partial, byteCount: 64 << 10)
        XCTAssertEqual(capacity.callCount, 2, "the sample must still refresh promptly for external disk use")
    }

    func testKnownLargeAssetMayExceedNormalPoolWhenCapacityAllows() throws {
        let capacity = CapacityProbe(100)
        let store = BackupTempFileStore(
            directory: directory,
            maximumBytes: 10,
            minimumFreeBytes: 5,
            availableCapacity: capacity.read,
            now: Date.init
        )

        let partial = try store.reserve(filename: "4k-video.mov", expectedBytes: 30)
        XCTAssertNoThrow(try store.recordWrite(to: partial, byteCount: 15))
        XCTAssertNoThrow(try store.recordWrite(to: partial, byteCount: 15))

        XCTAssertThrowsError(try store.reserve(filename: "next.heic", expectedBytes: 1)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }

        store.discard(partial)
        XCTAssertNoThrow(try store.reserve(filename: "next.heic", expectedBytes: 1))
    }

    func testKnownLargeAssetRequiresEnoughFreeCapacity() throws {
        let store = BackupTempFileStore(
            directory: directory,
            maximumBytes: 10,
            minimumFreeBytes: 5,
            availableCapacity: { _ in 34 },
            now: Date.init
        )

        XCTAssertThrowsError(try store.reserve(filename: "4k-video.mov", expectedBytes: 30)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
    }

    func testKnownLargeAssetCannotGrowPastItsIdentitySize() throws {
        let store = BackupTempFileStore(
            directory: directory,
            maximumBytes: 10,
            minimumFreeBytes: 0,
            availableCapacity: { _ in 100 },
            now: Date.init
        )
        let partial = try store.reserve(filename: "changed-video.mov", expectedBytes: 30)

        try store.recordWrite(to: partial, byteCount: 30)
        XCTAssertThrowsError(try store.recordWrite(to: partial, byteCount: 1)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
    }

    private func writeReserved(_ store: BackupTempFileStore, name: String) throws -> URL {
        let url = try store.reserve(filename: name, expectedBytes: 1)
        try Data("y".utf8).write(to: url)
        return url
    }
}
