import Foundation
import PhotosCore
import Testing
import UploadCore

@Suite @MainActor struct TrashEmptyingTests {
    @Test func pendingRemovalPrecedesGuardedTrashAndCommit() async throws {
        let fixture = Fixture()

        try await fixture.empty()

        #expect(fixture.pending.isEmpty)
        #expect(fixture.removed == [fixture.uid])
        #expect(fixture.events.values == ["pending", "exclude", "check", "trash", "release", "commit"])
    }

    @Test func mergeContextIsReadAfterPendingRemoval() async throws {
        let fixture = Fixture()
        func merger() -> Merger {
            fixture.events.add("merger-context")
            return fixture.merger
        }
        func directory() -> URL? {
            fixture.events.add("directory-context")
            return nil
        }

        try await TrashEmptying.empty(
            fixture.trash, pendingUIDs: fixture.pending,
            removePending: { _ in
                fixture.events.add("pending")
                await Task.yield()
                return true
            }, includesProtonTrash: true, checkingMergesWith: merger(), accountDataDirectory: directory(),
            commit: { fixture.events.add("commit") })

        #expect(
            fixture.events.values
                == ["pending", "merger-context", "directory-context", "exclude", "check", "trash", "release", "commit"])
    }

    @Test func pendingOnlySkipsProtonAndCommit() async throws {
        let fixture = Fixture()

        try await fixture.empty(includesProtonTrash: false)

        #expect(fixture.pending.isEmpty)
        #expect(fixture.events.values == ["pending"])
    }

    @Test func emptyPendingListSkipsRemovalAndStillEmptiesProton() async throws {
        let fixture = Fixture()
        fixture.pending = []
        fixture.removalSucceeds = false

        try await fixture.empty()

        #expect(fixture.removed.isEmpty)
        #expect(fixture.events.values == ["exclude", "check", "trash", "release", "commit"])
    }

    @Test func missingMobilePendingAdapterStillEmptiesProton() async throws {
        let fixture = Fixture()

        try await fixture.empty(hasPendingAdapter: false)

        #expect(fixture.pending == [fixture.uid])
        #expect(fixture.events.values == ["exclude", "check", "trash", "release", "commit"])
    }

    @Test func pendingFailureStopsBeforeProtonCommitAndRecovery() async {
        let fixture = Fixture()
        fixture.removalSucceeds = false

        await #expect(throws: CancellationError.self) { try await fixture.empty() }

        #expect(fixture.pending == [fixture.uid])
        #expect(fixture.events.values == ["pending"])
    }

    @Test func missingMacPendingSessionStopsBeforeProton() async {
        let fixture = Fixture()
        let remove: ([PhotoUID]) async -> Bool = { _ in
            let session: PendingRemoval? = nil
            return await session?.remove() == true
        }

        await #expect(throws: CancellationError.self) {
            try await TrashEmptying.empty(
                fixture.trash, pendingUIDs: fixture.pending, removePending: remove, includesProtonTrash: true,
                checkingMergesWith: fixture.merger, accountDataDirectory: nil,
                commit: { fixture.events.add("commit") },
                recoverFromTrashFailure: { _ in fixture.events.add("reload") })
        }

        #expect(fixture.events.values.isEmpty)
    }

    @Test func failedMergeCheckKeepsTrashAndRecoversWithoutCommit() async {
        let fixture = Fixture(confirmsNoPendingMerges: false)

        await #expect(throws: RecentlyDeletedEmptying.PendingMergeCheck.self) { try await fixture.empty() }

        #expect(fixture.pending.isEmpty, "successful local removal is not rolled back")
        #expect(fixture.events.values == ["pending", "exclude", "check", "release", "reload"])
        #expect(fixture.recoveredError is RecentlyDeletedEmptying.PendingMergeCheck)
    }

    @Test func failedExclusionKeepsTrashAndRecoversWithoutCommit() async {
        let fixture = Fixture(exclusionError: Failure.exclusion)

        await #expect(throws: Failure.exclusion) { try await fixture.empty() }

        #expect(fixture.pending.isEmpty)
        #expect(fixture.events.values == ["pending", "exclude", "reload"])
        #expect(fixture.recoveredError as? Failure == .exclusion)
    }

    @Test func failedTrashRecoversAndThrowsWithoutCommit() async {
        let fixture = Fixture(trashError: Failure.trash)

        await #expect(throws: Failure.trash) { try await fixture.empty() }

        #expect(fixture.pending.isEmpty)
        #expect(fixture.events.values == ["pending", "exclude", "check", "trash", "release", "reload"])
        #expect(fixture.recoveredError as? Failure == .trash)
    }

    @Test func recoveryCompletesBeforeTheOriginalErrorIsThrown() async {
        let original = RecoveryFailure()
        let fixture = Fixture(trashError: original)
        let gate = RecoveryGate()
        var finished = false
        var thrown: (any Error)?
        let operation = Task {
            do {
                try await TrashEmptying.empty(
                    fixture.trash, pendingUIDs: [], removePending: nil, includesProtonTrash: true,
                    checkingMergesWith: fixture.merger, accountDataDirectory: nil,
                    commit: { Issue.record("a failed trash call must not commit") },
                    recoverFromTrashFailure: { error in
                        #expect(error as? RecoveryFailure === original)
                        fixture.events.add("recovering")
                        await gate.wait()
                        fixture.events.add("recovered")
                    })
                Issue.record("the original error must propagate")
            } catch {
                thrown = error
                fixture.events.add("thrown")
            }
            finished = true
        }

        let deadline = ContinuousClock.now + .seconds(10)
        while !gate.entered && !finished && ContinuousClock.now < deadline { await Task.yield() }
        #expect(gate.entered, "recovery must start before the operation returns")
        #expect(!finished, "empty must remain suspended until recovery returns")
        #expect(thrown == nil)
        #expect(!fixture.events.values.contains("recovered"))
        gate.release()
        await operation.value

        #expect(thrown as? RecoveryFailure === original)
        #expect(fixture.events.values.suffix(3) == ["recovering", "recovered", "thrown"])
    }

    @Test func cancelledTrashAlsoRecoversWithoutCommit() async {
        let fixture = Fixture(trashError: CancellationError())

        await #expect(throws: CancellationError.self) { try await fixture.empty() }

        #expect(fixture.events.values == ["pending", "exclude", "check", "trash", "release", "reload"])
        #expect(fixture.recoveredError is CancellationError)
    }

    @Test func defaultRecoveryPropagatesTheMobileErrorWithoutCommit() async {
        let fixture = Fixture(trashError: Failure.trash)

        await #expect(throws: Failure.trash) {
            try await TrashEmptying.empty(
                fixture.trash, pendingUIDs: [], removePending: nil, includesProtonTrash: true,
                checkingMergesWith: fixture.merger, accountDataDirectory: nil,
                commit: { fixture.events.add("commit") })
        }

        #expect(fixture.events.values == ["exclude", "check", "trash", "release"])
    }

    @Test func withoutAMergerADamagedJournalKeepsTrashAndRecovers() async throws {
        let fixture = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a merge journal".utf8).write(
            to: directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName))

        await #expect(throws: RecentlyDeletedEmptying.PendingMergeCheck.self) {
            try await TrashEmptying.empty(
                fixture.trash, pendingUIDs: [], removePending: nil, includesProtonTrash: true,
                checkingMergesWith: nil, accountDataDirectory: directory,
                commit: { fixture.events.add("commit") },
                recoverFromTrashFailure: { _ in fixture.events.add("reload") })
        }

        #expect(fixture.events.values == ["reload"])
    }

    @Test func withoutAMergerTheExistingJournalFallbackStillEmpties() async throws {
        let fixture = Fixture()
        let trash = Trash(events: fixture.events, requiresExclusion: false, error: nil)

        try await TrashEmptying.empty(
            trash, pendingUIDs: [], removePending: nil, includesProtonTrash: true,
            checkingMergesWith: nil, accountDataDirectory: nil, commit: { fixture.events.add("commit") })

        #expect(fixture.events.values == ["trash", "commit"])
    }
}

private enum Failure: Error, Equatable { case exclusion, trash }

@MainActor private struct PendingRemoval {
    func remove() async -> Bool { true }
}

@MainActor private final class Fixture {
    let uid = PhotoUID(volumeID: "pending", nodeID: "local")
    let events = Events()
    var pending: [PhotoUID]
    var removed: [PhotoUID] = []
    var removalSucceeds = true
    var recoveredError: (any Error)?
    let merger: Merger
    let trash: Trash

    init(
        confirmsNoPendingMerges: Bool = true, exclusionError: (any Error)? = nil, trashError: (any Error)? = nil
    ) {
        pending = [uid]
        merger = Merger(events: events, confirmsNoPendingMerges: confirmsNoPendingMerges, error: exclusionError)
        trash = Trash(events: events, requiresExclusion: true, error: trashError)
    }

    func empty(includesProtonTrash: Bool = true, hasPendingAdapter: Bool = true) async throws {
        let remove: ([PhotoUID]) async -> Bool = { uids in
            self.events.add("pending")
            self.removed = uids
            guard self.removalSucceeds else { return false }
            self.pending.removeAll { uids.contains($0) }
            return true
        }
        try await TrashEmptying.empty(
            trash, pendingUIDs: pending, removePending: hasPendingAdapter ? remove : nil,
            includesProtonTrash: includesProtonTrash, checkingMergesWith: merger, accountDataDirectory: nil,
            commit: { self.events.add("commit") },
            recoverFromTrashFailure: { error in
                await Task.yield()
                self.events.add("reload")
                self.recoveredError = error
            })
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var excluding = false
    var values: [String] { lock.withLock { recorded } }
    func add(_ value: String) { lock.withLock { recorded.append(value) } }
    func setExcluding(_ value: Bool) { lock.withLock { excluding = value } }
    var isExcluding: Bool { lock.withLock { excluding } }
}

private struct Trash: TrashProvider {
    let events: Events
    let requiresExclusion: Bool
    let error: (any Error)?

    func trash(_ uids: [PhotoUID]) async throws { Issue.record("unexpected trash") }
    func restore(_ uids: [PhotoUID]) async throws { Issue.record("unexpected restore") }
    func emptyTrash() async throws {
        events.add(requiresExclusion && !events.isExcluding ? "unprotected-trash" : "trash")
        if let error { throw error }
    }
}

private struct Merger: ExactDuplicateMerging {
    let events: Events
    let confirmsNoPendingMerges: Bool
    let error: (any Error)?

    func confirmNoPendingMerges() async -> Bool {
        events.add("check")
        return confirmsNoPendingMerges
    }

    func excludingMerges(_ body: () async throws -> Void) async throws {
        events.add("exclude")
        if let error { throw error }
        events.setExcluding(true)
        defer {
            events.setExcluding(false)
            events.add("release")
        }
        try await body()
    }

    func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan { throw Failure.exclusion }
    func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool { throw Failure.exclusion }
    func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] { [:] }
    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async {}
    func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] { [] }
}

private final class RecoveryFailure: Error {}

@MainActor private final class RecoveryGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
