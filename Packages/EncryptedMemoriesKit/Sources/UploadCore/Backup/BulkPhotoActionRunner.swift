import Foundation
import Observation

/// Account-owned admission of an explicitly confirmed, fixed set of photos.
@MainActor
@Observable
public final class BulkPhotoActionRunner {
    public enum Action: Sendable { case backUpAgain, restore }

    public struct Confirmation: Equatable, Sendable {
        public let id: UUID
        public let action: Action
        public let items: [BackupFailedItem]
        public let revisionsBySource: [UploadSourceIdentity: Set<UploadBackupRevision>]
        public var count: Int { items.count }
    }

    public struct Summary: Equatable, Sendable {
        public let action: Action
        public let total: Int
        public let completed: Int
        public let stayed: Int
        public let cancelled: Bool
    }

    public private(set) var confirmation: Confirmation?
    public private(set) var summary: Summary?
    public private(set) var isRunning = false
    public private(set) var processed = 0
    public private(set) var completed = 0
    public private(set) var total = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<BackupProblemSnapshot?, Never>?
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async throws -> Void

    public convenience init() {
        self.init { try await Task.sleep(for: .seconds($0)) }
    }

    /// `sleep` paces the start of each later photo; tests can hold a run between two photos.
    public init(sleep: @escaping @MainActor (TimeInterval) async throws -> Void) {
        self.sleep = sleep
    }

    /// A snapshot is consent for these rows only. Preparing it never changes a row.
    public func prepare(_ items: [BackupFailedItem], action: Action) -> Confirmation? {
        guard !retired, !isRunning, confirmation == nil, !items.isEmpty else { return nil }
        let selection = BackupProblemPhotoSelection(
            items, decisionIssue: action == .backUpAgain ? .deletedElsewhere : .remoteDeletion)
        return storeConfirmation(selection.items, revisions: selection.revisionsBySource, action: action)
    }

    private func storeConfirmation(
        _ photos: [BackupFailedItem], revisions: [UploadSourceIdentity: Set<UploadBackupRevision>], action: Action
    ) -> Confirmation? {
        guard !retired, !isRunning, confirmation == nil, !photos.isEmpty else { return nil }
        let snapshot = Confirmation(id: UUID(), action: action, items: photos, revisionsBySource: revisions)
        confirmation = snapshot
        return snapshot
    }

    public func dismissConfirmation() { confirmation = nil }
    public func dismissSummary() {
        guard !isRunning else { return }
        summary = nil
        processed = 0
        completed = 0
        total = 0
    }

    /// Reads the whole reason group, independently of the problem sheet's presentation limit. No row changes here.
    public func prepareBackUpAgain(in queue: UploadBackupSyncQueueManifestStore) async -> Confirmation? {
        guard !retired, !isRunning, confirmation == nil, captureTask == nil else { return nil }
        let capture = Task.detached(priority: .utility) { BackupProblemSnapshot.backup(in: queue) }
        captureTask = capture
        let captured = await withTaskCancellationHandler {
            await capture.value
        } onCancel: {
            capture.cancel()
        }
        captureTask = nil
        guard !Task.isCancelled, let captured else { return nil }
        let targets = captured.rows.map(\.item).filter { $0.issue == .deletedElsewhere }
        return storeConfirmation(targets, revisions: captured.revisionsBySource, action: .backUpAgain)
    }

    /// Call only from the visible confirmation's affirmative action. A successful row means queued or restored,
    /// according to `action`, never that an upload finished. The operation keeps each failed row's reason.
    @discardableResult
    public func start(
        _ confirmation: Confirmation, perform: @escaping @MainActor (BackupFailedItem) async -> Bool
    ) -> Bool {
        guard !retired, !isRunning, self.confirmation == confirmation else { return false }
        self.confirmation = nil
        summary = nil
        isRunning = true
        processed = 0
        completed = 0
        stopRequested = false
        total = confirmation.count
        task = Task {
            for item in confirmation.items {
                guard !Task.isCancelled, !stopRequested else { break }
                if processed > 0 {
                    do { try await sleep(0.25) } catch { break }
                }
                guard !Task.isCancelled, !stopRequested else { break }
                if await perform(item) { completed += 1 }
                processed += 1
            }
            summary = Summary(
                action: confirmation.action, total: confirmation.count, completed: completed,
                stayed: confirmation.count - completed, cancelled: Task.isCancelled || stopRequested)
            isRunning = false
            task = nil
        }
        return true
    }

    /// Revokes further admission. A row already running reports its actual outcome before the run ends.
    public func cancel() { task?.cancel() }
    public func stopAfterCurrentPhoto() {
        guard isRunning else { return }
        stopRequested = true
    }
    public func waitUntilFinished() async { await task?.value }

    /// Sign-out joins the operation before the account closes its stores and rejects every later start.
    public func shutdown() async {
        retired = true
        confirmation = nil
        let capture = captureTask
        capture?.cancel()
        cancel()
        _ = await capture?.value
        await waitUntilFinished()
    }
}
