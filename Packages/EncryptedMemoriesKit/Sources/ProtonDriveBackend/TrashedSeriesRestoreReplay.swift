import Foundation
import PhotosCore
import UploadCore

/// Serializes foreground Restore, frame replay and deliberate trash for one account.
/// Replay never restores a main photo. Every request uses fresh, complete remote proof.
actor TrashedSeriesRestoreReplay {
    typealias Read = @Sendable ([PhotoUID]) async throws -> [PhotoUID: RemoteLinkVisibility]
    typealias Restore = @Sendable ([PhotoUID]) async throws -> Void
    nonisolated let journal: TrashedSeriesRestoreJournal?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var worker: Task<Void, Never>?
    private var closed = false
    var waitingOperations: Int { waiters.count }
    nonisolated let retry: BackupRetryPolicy

    init(url: URL, policy: LibraryDatabasePolicy, retry: BackupRetryPolicy = .init(baseDelay: 60, maxDelay: 900)) {
        journal = TrashedSeriesRestoreJournal(url: url, policy: policy)
        self.retry = retry
    }

    /// A shared account gate prevents an in-flight frame Restore from undoing a later deliberate trash.
    func exclusive<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return try await operation()
    }

    func start(read: @escaping Read, restore: @escaping Restore) {
        guard !closed, worker == nil, journal != nil else { return }
        worker = Task { [weak self] in
            await ProtonRequestContext.$priority.withValue(.maintenance) {
                await self?.run(read: read, restore: restore)
            }
        }
    }

    func shutdown() async {
        closed = true
        let task = worker
        task?.cancel()
        await task?.value
        worker = nil
        journal?.close()
    }

    /// Ends old authority before a deliberate trash, including a repeat within the same server timestamp second.
    func forget(_ uids: Set<PhotoUID>) throws {
        guard let journal else { throw TrashedSeriesRestoreJournal.unavailable }
        for var record in try journal.records() {
            record.frames = uids.contains(record.main) ? [] : record.frames.filter { !uids.contains($0.uid) }
            try journal.update(record)
        }
    }

    private func run(read: @escaping Read, restore: @escaping Restore) async {
        defer { worker = nil }
        while !Task.isCancelled && !closed {
            do {
                try await exclusive { [self] in
                    guard let journal else { throw TrashedSeriesRestoreJournal.unavailable }
                    let due = try journal.records().filter { $0.retryAt <= Date() }
                    _ = await resume(due, read: read, restore: restore)
                }
                guard !Task.isCancelled, !closed, let journal else { return }
                let records = try journal.records()
                guard let next = records.map(\.retryAt).min() else { return }
                try await Task.sleep(for: .seconds(max(1, min(60, next.timeIntervalSinceNow))))
            } catch is CancellationError {
                return
            } catch {
                DebugLog.log("restore: journal replay deferred")
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    /// Called under `exclusive`, also directly after the foreground main Restore.
    func resume(_ records: [TrashedSeriesRestoreRecord], read: Read, restore: Restore) async -> [PhotoUID] {
        guard let journal else { return [] }
        var restored: [PhotoUID] = []
        for var record in records {
            do {
                try Task.checkCancellation()
                guard
                    try journal.records().contains(where: {
                        $0.main == record.main && $0.generation == record.generation
                    })
                else {
                    continue
                }
                let snapshot = try await read([record.main] + record.frames.map(\.uid))
                let eligible = reconcile(&record, snapshot: snapshot)
                if !eligible.isEmpty {
                    try Task.checkCancellation()
                    guard
                        try journal.records().contains(where: {
                            $0.main == record.main && $0.generation == record.generation
                        })
                    else {
                        continue
                    }
                    do {
                        try await restore(eligible.map(\.uid))
                        record.frames.removeAll { eligible.contains($0) }
                        restored.append(contentsOf: eligible.map(\.uid))
                    } catch {
                        // Proton can apply part or all of a batch before its response is lost.
                        try Task.checkCancellation()
                        let after = try await read([record.main] + record.frames.map(\.uid))
                        _ = reconcile(&record, snapshot: after)
                    }
                }
            } catch {
                // Unknown state and cancellation preserve proof. A later account owner can resume it.
                DebugLog.log("restore: frame duties retained")
            }
            record.attempts = min(32, record.attempts + 1)
            record.retryAt = Date().addingTimeInterval(retry.delay(afterAttempts: record.attempts))
            do { try journal.update(record) } catch { DebugLog.log("restore: frame settlement deferred") }
            if Task.isCancelled { break }
        }
        return restored
    }

    /// An omitted row is gone only because `read` requires an authoritative complete response.
    /// Explicit state with changed proof ends old authority. Unknown state leaves it untouched.
    private func reconcile(
        _ record: inout TrashedSeriesRestoreRecord, snapshot: [PhotoUID: RemoteLinkVisibility]
    ) -> [TrashedSeriesRestoreRecord.Frame] {
        guard let main = snapshot[record.main] else {
            record.frames = []
            return []
        }
        guard main.hasExplicitPhotoState else { return [] }
        if let trash = main.trashTime, trash != record.mainTrashTime {
            record.frames = []
            return []
        }
        guard main.isActive else { return [] }
        var eligible: [TrashedSeriesRestoreRecord.Frame] = []
        record.frames.removeAll { frame in
            guard let state = snapshot[frame.uid] else { return true }
            guard state.hasExplicitPhotoState else { return false }
            if state.isActive { return true }
            guard let trash = state.trashTime else { return false }
            guard state.mainPhotoLinkID == frame.mainPhotoLinkID, trash == frame.trashTime else { return true }
            eligible.append(frame)
            return false
        }
        return eligible
    }
}
