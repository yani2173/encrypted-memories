import AlbumSyncCore
import Foundation
import PhotosCore
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

@MainActor
final class AccountBackupStackTests: XCTestCase {
    func testTheStackOpensTheStoreAndBuildsBothControllersForTheAccount() async throws {
        let directory = try makeAccountDirectory()
        let stack = makeStack(directory)

        let store = try XCTUnwrap(stack.pendingStore, "the pending store opens in the account folder")
        XCTAssertTrue(store.isOperational())
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path))
        XCTAssertNotNil(stack.photoBackup.pendingRecorder, "the photo backup records into that store")
        XCTAssertTrue(stack.photoBackup.isAvailable)
        XCTAssertTrue(stack.albumSync.isAvailable)

        await stack.shutdownUnused()
    }

    /// Without readable exclusions a photo that the person deleted before its upload could upload, so a missing store
    /// keeps the photo backup from running.
    func testAMissingStorePreventsBackup() async throws {
        let directory = try makeAccountDirectory()
        // A file where the store's database belongs makes the store fail to open.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName),
            withIntermediateDirectories: true)
        let stack = makeStack(directory)

        XCTAssertNil(stack.pendingStore)
        XCTAssertNil(stack.photoBackup.pendingRecorder)
        XCTAssertFalse(stack.photoBackup.isAvailable, "backup refuses to run without its pending store")

        await stack.shutdownUnused()
    }

    /// A load that was cancelled or replaced closes the stack it built: the photo backup, then its store, then album
    /// sync. Nothing of it stays open for the next account.
    func testAStackThatNeverReachedTheAccountClosesEverything() async throws {
        let directory = try makeAccountDirectory()
        let stack = makeStack(directory)
        let store = try XCTUnwrap(stack.pendingStore)

        await stack.shutdownUnused()

        XCTAssertFalse(store.isOperational(), "the pending store is closed")
        XCTAssertFalse(stack.photoBackup.isAvailable)
        #if DEBUG
            // A closed pending store alone already makes the backup unavailable; its own queue store proves the shutdown.
            XCTAssertEqual(
                stack.photoBackup.queueStoreForTesting?.isOperational(), false, "the photo backup is shut down")
        #endif
        XCTAssertFalse(stack.albumSync.isAvailable, "album sync is shut down")
    }

    /// Replacing the account builds a new stack in the new account's folder; the earlier one is untouched until its
    /// owner closes it.
    func testTwoAccountsGetIndependentStacks() async throws {
        let first = makeStack(try makeAccountDirectory())
        let second = makeStack(try makeAccountDirectory())
        let firstStore = try XCTUnwrap(first.pendingStore)
        let secondStore = try XCTUnwrap(second.pendingStore)
        XCTAssertFalse(firstStore === secondStore)

        await first.shutdownUnused()
        XCTAssertFalse(firstStore.isOperational())
        XCTAssertTrue(secondStore.isOperational(), "closing one account's stack leaves the other open")
        XCTAssertTrue(second.photoBackup.isAvailable)

        await second.shutdownUnused()
    }

    func testAccountCompositionObservesChangesAndStopsConsumersIndependently() async throws {
        let fixture = try makeChangeFixture()
        defer { fixture.clock.releaseAll() }
        let stack = fixture.stack
        await changeCondition { fixture.probe.registeredCount == fixture.tokenNames.count }
        XCTAssertEqual(fixture.probe.fetchCount, 1)
        XCTAssertEqual(fixture.tokenNames, ["photo-backup-change-token.v1"])
        await changeCondition { fixture.clock.count(.seconds(3)) == 1 }
        fixture.probe.emit()
        XCTAssertEqual(fixture.probe.detailCount, 1)
        await changeCondition { fixture.clock.count(.milliseconds(750)) == 1 }
        stack.photoBackup.disableBackup()
        XCTAssertEqual(fixture.probe.registeredCount, 1)
        fixture.probe.emit()
        await changeCondition { fixture.clock.count(.seconds(3)) == 1 }
        XCTAssertEqual(fixture.probe.detailCount, 2)
        await stack.shutdownUnused()
        XCTAssertEqual(fixture.probe.registeredCount, 0)
    }

    func testAlbumCatchUpAndOneRefreshPerChangeWorkWithBackupDisabled() async throws {
        let fixture = try makeChangeFixture(backupEnabled: false)
        defer { fixture.clock.releaseAll() }
        await changeCondition { fixture.probe.registeredCount == 1 && fixture.clock.count(.seconds(3)) == 1 }
        XCTAssertEqual(fixture.source.listCalls, 0)
        fixture.clock.release(.seconds(3))
        await changeCondition {
            fixture.stack.albumSync.progress.phase == .completed && !fixture.stack.albumSync.isSyncing
        }
        XCTAssertEqual(fixture.source.listCalls, 1, "Init catch-up reads albums once")
        fixture.probe.emit()
        await changeCondition { fixture.clock.count(.seconds(3)) == 1 }
        XCTAssertEqual(fixture.source.listCalls, 1, "A change keeps the existing three-second debounce")
        fixture.clock.release(.seconds(3))
        await changeCondition { fixture.source.listCalls == 2 }
        await fixture.stack.shutdownUnused()
        XCTAssertEqual(fixture.source.listCalls, 2)
        XCTAssertEqual(fixture.probe.fetchCount, 1)
        XCTAssertEqual(fixture.probe.detailCount, 1)
    }

    func testAccountRetirementDoesNotNotifyOrStopAnotherAccount() async throws {
        let first = try makeChangeFixture(backupEnabled: false)
        let second = try makeChangeFixture(backupEnabled: false)
        defer {
            first.clock.releaseAll()
            second.clock.releaseAll()
        }
        await changeCondition {
            first.clock.count(.seconds(3)) == 1 && second.clock.count(.seconds(3)) == 1
                && first.probe.registeredCount == 1 && second.probe.registeredCount == 1
        }
        first.probe.emit()
        await changeCondition { first.clock.requestCount(.seconds(3)) == 2 }
        XCTAssertEqual(second.clock.requestCount(.seconds(3)), 1)
        await first.stack.shutdownUnused()
        first.probe.emitRetired()
        XCTAssertEqual(second.probe.registeredCount, 1)
        XCTAssertEqual(second.clock.requestCount(.seconds(3)), 1)
        second.probe.emit()
        await changeCondition { second.clock.requestCount(.seconds(3)) == 2 }
        await second.stack.shutdownUnused()
    }

    func testAlbumStopCancelsTheHeldCatchUpAndPreservesTheNextChange() async throws {
        let fixture = try makeChangeFixture(backupEnabled: false)
        defer { fixture.clock.releaseAll() }
        await changeCondition { fixture.clock.count(.seconds(3)) == 1 && fixture.probe.registeredCount == 1 }
        fixture.stack.albumSync.stopSync()
        await changeCondition { fixture.clock.count(.seconds(3)) == 0 }
        XCTAssertEqual(fixture.source.listCalls, 0)
        fixture.probe.emit()
        await changeCondition { fixture.clock.count(.seconds(3)) == 1 }
        fixture.clock.release(.seconds(3))
        await changeCondition { fixture.source.listCalls == 1 }
        await fixture.stack.shutdownUnused()
        XCTAssertEqual(fixture.source.listCalls, 1)
    }

    func testAlbumReadFailureStillReachesTheController() async throws {
        let fixture = try makeChangeFixture(backupEnabled: false)
        defer { fixture.clock.releaseAll() }
        fixture.source.failContents = true
        await changeCondition { fixture.clock.count(.seconds(3)) == 1 }
        fixture.clock.release(.seconds(3))
        await changeCondition { fixture.stack.albumSync.lastMessage == "Album input failed" }
        XCTAssertEqual(fixture.stack.albumSync.lastMessageStyle, .error)
        await fixture.stack.shutdownUnused()
    }

    #if DEBUG
        func testBackupChangeKeepsItsDebounceAndStartsOneInjectedPass() async throws {
            let fixture = try makeChangeFixture(backupPaused: false)
            defer { fixture.clock.releaseAll() }
            await changeCondition {
                fixture.passCalls.value("pass") == 1 && !fixture.stack.photoBackup.isSyncing
                    && fixture.probe.registeredCount == 1 && fixture.clock.count(.seconds(3)) == 1
            }
            fixture.probe.emit()
            await changeCondition { fixture.clock.count(.milliseconds(750)) == 1 }
            XCTAssertEqual(fixture.passCalls.value("pass"), 1)
            fixture.clock.release(.milliseconds(750))
            await changeCondition { fixture.passCalls.value("pass") == 2 && !fixture.stack.photoBackup.isSyncing }
            await fixture.stack.shutdownUnused()
            XCTAssertEqual(fixture.passCalls.value("pass"), 2)
            XCTAssertEqual(fixture.source.listCalls, 0, "Album still waits for its own three-second clock")
            XCTAssertEqual(fixture.probe.fetchCount, 1)
            XCTAssertEqual(fixture.probe.detailCount, 1)
        }
    #endif

    func testChangesDuringAlbumSyncScheduleOnlyOneFreshFollowUp() async throws {
        let fixture = try makeChangeFixture(backupEnabled: false)
        let gate = PhotoAlbumReadGate()
        fixture.source.gate = gate
        defer {
            gate.release()
            fixture.clock.releaseAll()
        }
        await changeCondition { fixture.clock.count(.seconds(3)) == 1 && fixture.probe.registeredCount == 1 }
        fixture.clock.release(.seconds(3))
        await changeCondition { fixture.stack.albumSync.isSyncing && gate.isWaiting }
        fixture.probe.emit()
        fixture.probe.emit()
        XCTAssertEqual(fixture.source.listCalls, 1)
        XCTAssertEqual(fixture.clock.count(.seconds(3)), 0)
        gate.release()
        await changeCondition { !fixture.stack.albumSync.isSyncing && fixture.clock.count(.seconds(3)) == 1 }
        XCTAssertEqual(fixture.source.listCalls, 1)
        fixture.clock.release(.seconds(3))
        await changeCondition { fixture.source.listCalls == 2 }
        await fixture.stack.shutdownUnused()
        XCTAssertEqual(fixture.source.listCalls, 2)
        XCTAssertEqual(fixture.probe.detailCount, 2)
    }

    private struct ChangeFixture {
        let stack: AccountBackupStack
        let probe: PhotoChangeOperationsProbe
        let clock: PhotoChangeSleepGate
        let tokenNames: [String]
        let passCalls: ChangeCallCounter
        let source: ChangeAlbumSource
    }

    private func makeChangeFixture(backupEnabled: Bool = true, backupPaused: Bool = true) throws -> ChangeFixture {
        let directory = try makeAccountDirectory()
        let store = try XCTUnwrap(
            AlbumSyncMappingStore(
                url: directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        XCTAssertTrue(store.addSelection(.init(localAlbumID: "album", title: "Album", addedAt: Date())))
        store.close()
        let suite = "account-change-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(backupEnabled, forKey: "photoBackup.enabled.v1")
        defaults.set(backupPaused, forKey: "photoBackup.userPaused.v1")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let probe = PhotoChangeOperationsProbe()
        let clock = PhotoChangeSleepGate()
        var tokens: [String] = []
        var dependencies = AccountBackupStack.Dependencies()
        dependencies.makeChangeMonitor = { url in
            tokens.append(url.lastPathComponent)
            return PhotoLibraryChangeMonitor(tokenURL: url, operations: probe.operations)
        }
        dependencies.currentAccessState = { .full }
        dependencies.changeSleep = { try await clock.sleep(.nanoseconds(Int64($0))) }
        let source = ChangeAlbumSource()
        dependencies.localAlbumSource = source
        dependencies.defaults = defaults
        dependencies.runtimeSignals = .wiFiWithMobileDataOff
        let stack = AccountBackupStack(
            accountDataDirectory: directory, databasePolicy: .conservative, identityResolver: FakeIdentityResolver(),
            uploader: MockUploader(), tagAdder: nil, editReplacement: nil, albumOperations: NoRemoteAlbums(),
            dependencies: dependencies)
        let passCalls = ChangeCallCounter()
        #if DEBUG
            stack.photoBackup.replacePassBodyForTesting { passCalls.increment("pass") }
        #endif
        addTeardownBlock {
            await stack.shutdownUnused()
            clock.releaseAll()
        }
        return ChangeFixture(
            stack: stack, probe: probe, clock: clock, tokenNames: tokens, passCalls: passCalls, source: source)
    }

    private func makeStack(_ directory: URL) -> AccountBackupStack {
        AccountBackupStack(
            accountDataDirectory: directory, databasePolicy: .conservative, identityResolver: FakeIdentityResolver(),
            uploader: MockUploader(), tagAdder: nil, editReplacement: nil, albumOperations: NoRemoteAlbums())
    }

    private func makeAccountDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-backup-stack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private struct NoRemoteAlbums: AlbumSyncRemoteAlbumOps {
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
    func createAlbum(name: String) async throws -> String { "remote-1" }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        AlbumSyncAttachResult()
    }
}

private final class ChangeAlbumSource: AlbumSyncLocalAlbumSource, @unchecked Sendable {
    private let lock = NSLock()
    private var held: PhotoAlbumReadGate?
    var gate: PhotoAlbumReadGate? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
    private var lists = 0
    private var failure = false
    var listCalls: Int { lock.withLock { lists } }
    var failContents: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    func listAlbums() async throws -> [LocalAlbumSummary] {
        lock.withLock { lists += 1 }
        return [.init(id: "album", title: "Album", assetCount: 0)]
    }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents {
        if failContents {
            throw NSError(domain: "album-fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Album input failed"])
        }
        await gate?.wait()
        return .present([])
    }
}

private final class PhotoAlbumReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waits: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { lock.withLock { !waits.isEmpty } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if open { return true }
                waits.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock {
            open = true
            let pending = waits
            waits.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
}
