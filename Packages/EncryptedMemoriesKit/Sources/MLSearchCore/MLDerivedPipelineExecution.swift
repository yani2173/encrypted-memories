import Foundation
import PhotosCore

public struct MLPipelineExecutionKey: Codable, Equatable, Hashable, Sendable {
    public let accountIdentifier: String
    public let pipelineID: MLPipelineID
    public let schemaVersion: Int
    public let artifacts: Set<MLDerivedArtifactIdentity>

    public init(
        accountIdentifier: String,
        pipelineID: MLPipelineID,
        schemaVersion: Int,
        artifacts: Set<MLDerivedArtifactIdentity>
    ) throws {
        guard !accountIdentifier.isEmpty, schemaVersion > 0, !artifacts.isEmpty,
            artifacts.allSatisfy({ $0.pipelineID == pipelineID })
        else {
            throw MLDerivedPipelineContractError.invalidExecutionKey
        }
        self.accountIdentifier = accountIdentifier
        self.pipelineID = pipelineID
        self.schemaVersion = schemaVersion
        self.artifacts = artifacts
    }
}

public struct MLPipelineAssetRevision: Codable, Equatable, Hashable, Sendable {
    public let uid: PhotoUID
    public let sourceRevision: String

    public init(uid: PhotoUID, sourceRevision: String) throws {
        guard !sourceRevision.isEmpty else {
            throw MLDerivedPipelineContractError.invalidSourceRevision
        }
        self.uid = uid
        self.sourceRevision = sourceRevision
    }
}

public struct MLDerivedPipelineWorkItem: Codable, Equatable, Hashable, Sendable {
    public let asset: MLPipelineAssetRevision
    public let artifact: MLDerivedArtifactIdentity
    public let attempts: Int

    public init(asset: MLPipelineAssetRevision, artifact: MLDerivedArtifactIdentity, attempts: Int = 0) {
        self.asset = asset
        self.artifact = artifact
        self.attempts = max(0, attempts)
    }
}

public struct MLAssetAnalysisPlan: Sendable, Equatable {
    public let asset: MLPipelineAssetRevision
    public let workItems: [MLDerivedPipelineWorkItem]

    public init(asset: MLPipelineAssetRevision, workItems: [MLDerivedPipelineWorkItem]) throws {
        guard !workItems.isEmpty, workItems.allSatisfy({ $0.asset == asset }) else {
            throw MLDerivedPipelineContractError.invalidAnalysisPlan
        }
        self.asset = asset
        self.workItems = workItems
    }
}

public enum MLPipelineSkipReason: String, Codable, Equatable, Hashable, Sendable {
    case sourceRemoved
    case sourceUnavailable
    case unsupportedMedia
    case unsupportedCapability
    case emptyOutput
    case belowConfidenceThreshold
}

public enum MLPipelineFailureReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case sourceCorrupt
    case invalidArtifactContract
    case invalidExecutorResult
    case analysisFailed
    case retryLimitReached
}

public enum MLPipelineDeferralReason: String, Codable, Equatable, Hashable, Sendable {
    case sourceNotResident
}

public enum MLPipelineSuspensionReason: String, Codable, Equatable, Hashable, Sendable {
    case resourcePolicy
    case thermal
    case lowPower
    case memoryPressure
    case insufficientStorage
    case userVisibleWork
}

public struct MLDerivedPipelineOutput: Codable, Equatable, Sendable {
    /// Encoded artifact payload before persistence encryption. Stores must encrypt this value
    /// before it reaches disk and decrypt it only for an explicit artifact read.
    public let payload: Data
    public let normalizedSearchTokens: [String]

    public init(payload: Data, normalizedSearchTokens: [String] = []) {
        self.payload = payload
        self.normalizedSearchTokens = Array(Set(normalizedSearchTokens.filter { !$0.isEmpty })).sorted()
    }
}

public enum MLPipelineStageOutcome: Equatable, Sendable {
    case completed(MLDerivedPipelineOutput)
    /// A request ran successfully and found nothing. This is a durable successful completion, not
    /// a skip or failure, and prevents the same empty request from being repeated forever.
    case completedEmpty
    case skipped(MLPipelineSkipReason)
    /// The input is valid but not locally resident yet. Deferrals never consume the failure retry budget.
    case deferred(reason: MLPipelineDeferralReason, retryAfter: Date?)
    case retryableFailure(reason: MLPipelineFailureReason, retryAfter: Date?)
    case permanentInputFailure(reason: MLPipelineFailureReason)
    case cancelled
    case suspended(MLPipelineSuspensionReason)
}

extension MLPipelineStageOutcome {
    var consumesAttempt: Bool {
        switch self {
        case .deferred, .suspended, .cancelled: false
        default: true
        }
    }
}

public struct MLPipelineStageResult: Equatable, Sendable {
    public let workItem: MLDerivedPipelineWorkItem
    public let outcome: MLPipelineStageOutcome

    public init(workItem: MLDerivedPipelineWorkItem, outcome: MLPipelineStageOutcome) {
        self.workItem = workItem
        self.outcome = outcome
    }
}

public protocol MLDerivedPipelineExecutor: Sendable {
    /// Executes every requested stage over one bounded decoded input. Results remain independent:
    /// one optional request failing must not discard another stage's durable output.
    func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult]
}

public struct MLDerivedPipelineProgress: Codable, Equatable, Sendable {
    public let total: Int
    public let completed: Int
    public let skipped: Int
    public let permanentFailure: Int
    public let retryPending: Int
    /// Unique assets with at least one genuine permanent analysis failure. Optional unsupported
    /// requests, removed sources and empty results never contribute to this user-facing count.
    public let unavailableAssets: Int
    public let unavailableAssetReasons: [MLPipelineFailureReason: Int]
    public let generation: UInt64

    public init(
        total: Int,
        completed: Int,
        skipped: Int,
        permanentFailure: Int,
        retryPending: Int,
        unavailableAssets: Int = 0,
        unavailableAssetReasons: [MLPipelineFailureReason: Int] = [:],
        generation: UInt64
    ) {
        self.total = max(0, total)
        self.completed = max(0, completed)
        self.skipped = max(0, skipped)
        self.permanentFailure = max(0, permanentFailure)
        self.retryPending = max(0, retryPending)
        self.unavailableAssets = max(0, unavailableAssets)
        self.unavailableAssetReasons = unavailableAssetReasons.filter { $0.value > 0 }
        self.generation = generation
    }

    public var settled: Int { completed + skipped + permanentFailure }
    public var pending: Int { max(0, total - settled) }
    public var isComplete: Bool { total == settled }
}

public struct MLDerivedSearchHit: Equatable, Sendable {
    public let uid: PhotoUID
    public let matchedTokenCount: Int

    public init(uid: PhotoUID, matchedTokenCount: Int) {
        self.uid = uid
        self.matchedTokenCount = matchedTokenCount
    }
}

public enum MLDerivedPipelineStoreError: Error, Equatable, Sendable {
    case storageUnavailable
    case corruptData
}

public protocol MLDerivedPipelineStore: Sendable {
    /// Idempotently schedules current source revisions. A changed source revision reopens only the
    /// corresponding asset/artifact work row.
    @discardableResult
    func enqueue(_ assets: [MLPipelineAssetRevision], for key: MLPipelineExecutionKey) -> Bool

    /// Returns a bounded, indexed work page. Implementations must not load encrypted payloads here.
    /// Candidate order is a store-owned scheduling policy: a persistent store may select retries by
    /// due time before grouping the bounded page by asset. Callers must not depend on global order.
    func nextWorkBatch(
        for key: MLPipelineExecutionKey,
        limit: Int,
        now: Date
    ) throws -> [MLDerivedPipelineWorkItem]

    /// Commits output and durable outcome together. Observer progress may advance only after this
    /// returns `true`.
    @discardableResult
    func commit(
        _ results: [MLPipelineStageResult],
        for key: MLPipelineExecutionKey,
        now: Date
    ) -> Bool

    func progress(for key: MLPipelineExecutionKey) throws -> MLDerivedPipelineProgress
    func unavailableAssetUIDs(for key: MLPipelineExecutionKey) throws -> Set<PhotoUID>
    func output(
        for uid: PhotoUID,
        artifact: MLDerivedArtifactIdentity,
        accountIdentifier: String
    ) -> MLDerivedPipelineOutput?
    func search(
        normalizedTokens: [String],
        in key: MLPipelineExecutionKey,
        limit: Int
    ) -> [MLDerivedSearchHit]
    /// Returns `true` when at least one committed token row exists for the key's artifacts under the
    /// account. An unreadable store returns `false`, so callers treat an unknown index as empty.
    func hasIndexedEntries(for key: MLPipelineExecutionKey) -> Bool
    /// Removes artifacts for assets that are no longer present in the authoritative library
    /// inventory. Call only after a complete inventory pass so a partial crawl cannot erase data.
    @discardableResult
    func reconcile(liveUIDs: Set<PhotoUID>, for key: MLPipelineExecutionKey) -> Bool
    func purge(artifact: MLDerivedArtifactIdentity, accountIdentifier: String)
    func purge(pipelineID: MLPipelineID, accountIdentifier: String)
    func close()
}

public extension MLDerivedPipelineStore {
    func close() {}
}

public struct MLDerivedPipelineObserver: Sendable {
    private let progressUpdated: MLLatestEventSink<MLDerivedPipelineProgress>

    public init(progressUpdated: @escaping @Sendable (MLDerivedPipelineProgress) async -> Void = { _ in }) {
        self.progressUpdated = MLLatestEventSink(deliver: progressUpdated)
    }

    func report(_ progress: MLDerivedPipelineProgress) {
        progressUpdated.yield(progress)
    }
}

public enum MLDerivedPipelineStopReason: Equatable, Sendable {
    case drained
    case workQuantumCompleted
    case retryPending
    case policySuspended
    case cancelled
    case storageFailure
}

public struct MLDerivedPipelinePassOutcome: Equatable, Sendable {
    public let reason: MLDerivedPipelineStopReason
    public let progress: MLDerivedPipelineProgress

    public init(reason: MLDerivedPipelineStopReason, progress: MLDerivedPipelineProgress) {
        self.reason = reason
        self.progress = progress
    }
}

public enum MLDerivedPipelineContractError: Error, Equatable {
    case invalidExecutionKey
    case invalidSourceRevision
    case invalidAnalysisPlan
}

public final class InMemoryMLDerivedPipelineStore: MLDerivedPipelineStore, @unchecked Sendable {
    private enum State: Equatable {
        case pending
        case completed
        case skipped(MLPipelineSkipReason)
        case permanentFailure(MLPipelineFailureReason)
        case retry(Date)
    }

    private struct Key: Hashable {
        let accountIdentifier: String
        let namespace: String
        let uid: PhotoUID
    }

    private struct Record {
        var asset: MLPipelineAssetRevision
        let artifact: MLDerivedArtifactIdentity
        var state: State
        var attempts: Int
        var output: MLDerivedPipelineOutput?
    }

    private let lock = NSLock()
    private var records: [Key: Record] = [:]
    private var generations: [String: UInt64] = [:]

    public init() {}

    @discardableResult
    public func enqueue(_ assets: [MLPipelineAssetRevision], for key: MLPipelineExecutionKey) -> Bool {
        lock.withLock {
            let existingArtifacts = Set(
                records.compactMap { storedKey, record in
                    storedKey.accountIdentifier == key.accountIdentifier
                        && record.artifact.pipelineID == key.pipelineID
                        ? record.artifact
                        : nil
                })
            let staleArtifacts = MLDerivedArtifactInvalidationPolicy.staleArtifacts(
                existing: existingArtifacts,
                current: key.artifacts
            )
            let obsoleteKeys = records.compactMap { storedKey, record in
                storedKey.accountIdentifier == key.accountIdentifier
                    && staleArtifacts.contains(record.artifact)
                    ? storedKey
                    : nil
            }
            for obsoleteKey in obsoleteKeys { records.removeValue(forKey: obsoleteKey) }
            var changed = !obsoleteKeys.isEmpty
            for asset in Set(assets) {
                for artifact in key.artifacts {
                    let recordKey = Key(
                        accountIdentifier: key.accountIdentifier,
                        namespace: artifact.stableNamespace,
                        uid: asset.uid
                    )
                    if var record = records[recordKey] {
                        guard record.asset.sourceRevision != asset.sourceRevision else { continue }
                        record.asset = asset
                        record.state = .pending
                        record.attempts = 0
                        record.output = nil
                        records[recordKey] = record
                    } else {
                        records[recordKey] = Record(
                            asset: asset,
                            artifact: artifact,
                            state: .pending,
                            attempts: 0,
                            output: nil
                        )
                    }
                    changed = true
                }
            }
            if changed { bumpGeneration(key) }
            return true
        }
    }

    public func nextWorkBatch(
        for key: MLPipelineExecutionKey,
        limit: Int,
        now: Date
    ) throws -> [MLDerivedPipelineWorkItem] {
        guard limit > 0 else { return [] }
        return lock.withLock {
            records.compactMap { storedKey, record -> MLDerivedPipelineWorkItem? in
                guard storedKey.accountIdentifier == key.accountIdentifier,
                    key.artifacts.contains(record.artifact)
                else { return nil }
                switch record.state {
                case .pending: break
                case .retry(let retryAt) where retryAt <= now: break
                default: return nil
                }
                return MLDerivedPipelineWorkItem(
                    asset: record.asset,
                    artifact: record.artifact,
                    attempts: record.attempts
                )
            }
            .sorted(by: Self.workOrder)
            .prefix(limit)
            .map { $0 }
        }
    }

    @discardableResult
    public func commit(
        _ results: [MLPipelineStageResult],
        for key: MLPipelineExecutionKey,
        now: Date
    ) -> Bool {
        lock.withLock {
            var changed = false
            for result in results {
                let work = result.workItem
                guard key.artifacts.contains(work.artifact) else { continue }
                let recordKey = Key(
                    accountIdentifier: key.accountIdentifier,
                    namespace: work.artifact.stableNamespace,
                    uid: work.asset.uid
                )
                guard var record = records[recordKey], record.asset == work.asset else { continue }
                switch result.outcome {
                case .completed(let output):
                    record.state = .completed
                    record.output = output
                case .completedEmpty:
                    record.state = .completed
                    record.output = nil
                case .skipped(let reason):
                    record.state = .skipped(reason)
                    record.output = nil
                case .deferred(_, let retryAfter):
                    record.state = .retry(retryAfter ?? now)
                    record.output = nil
                case .retryableFailure(_, let retryAfter):
                    record.state = .retry(retryAfter ?? now)
                    record.output = nil
                case .permanentInputFailure(let reason):
                    record.state = .permanentFailure(reason)
                    record.output = nil
                case .cancelled, .suspended:
                    continue
                }
                if result.outcome.consumesAttempt { record.attempts += 1 }
                records[recordKey] = record
                changed = true
            }
            if changed { bumpGeneration(key) }
            return true
        }
    }

    public func progress(for key: MLPipelineExecutionKey) throws -> MLDerivedPipelineProgress {
        lock.withLock {
            var completed = 0
            var skipped = 0
            var permanent = 0
            var retry = 0
            var total = 0
            var failureByAsset: [PhotoUID: MLPipelineFailureReason] = [:]
            for (storedKey, record) in records
            where storedKey.accountIdentifier == key.accountIdentifier && key.artifacts.contains(record.artifact) {
                total += 1
                switch record.state {
                case .completed: completed += 1
                case .skipped: skipped += 1
                case .permanentFailure(let reason):
                    permanent += 1
                    let current = failureByAsset[record.asset.uid]
                    if current == nil || reason.rawValue < current!.rawValue {
                        failureByAsset[record.asset.uid] = reason
                    }
                case .retry: retry += 1
                case .pending: break
                }
            }
            return MLDerivedPipelineProgress(
                total: total,
                completed: completed,
                skipped: skipped,
                permanentFailure: permanent,
                retryPending: retry,
                unavailableAssets: failureByAsset.count,
                unavailableAssetReasons: Dictionary(
                    grouping: failureByAsset.values,
                    by: { $0 }
                ).mapValues(\.count),
                generation: generations[generationKey(key)] ?? 0
            )
        }
    }

    public func unavailableAssetUIDs(for key: MLPipelineExecutionKey) -> Set<PhotoUID> {
        lock.withLock {
            Set(
                records.compactMap { storedKey, record in
                    guard storedKey.accountIdentifier == key.accountIdentifier,
                        key.artifacts.contains(record.artifact),
                        case .permanentFailure = record.state
                    else { return nil }
                    return record.asset.uid
                })
        }
    }

    public func output(
        for uid: PhotoUID,
        artifact: MLDerivedArtifactIdentity,
        accountIdentifier: String
    ) -> MLDerivedPipelineOutput? {
        lock.withLock {
            records[
                Key(
                    accountIdentifier: accountIdentifier,
                    namespace: artifact.stableNamespace,
                    uid: uid
                )]?.output
        }
    }

    public func search(
        normalizedTokens: [String],
        in key: MLPipelineExecutionKey,
        limit: Int
    ) -> [MLDerivedSearchHit] {
        let query = Set(normalizedTokens.filter { !$0.isEmpty })
        guard !query.isEmpty, limit > 0 else { return [] }
        return lock.withLock {
            var indexedTokens: [PhotoUID: Set<String>] = [:]
            for (storedKey, record) in records
            where storedKey.accountIdentifier == key.accountIdentifier && key.artifacts.contains(record.artifact) {
                guard case .completed = record.state, let output = record.output else { continue }
                indexedTokens[record.asset.uid, default: []].formUnion(output.normalizedSearchTokens)
            }
            return indexedTokens.compactMap { uid, tokens in
                query.isSubset(of: tokens)
                    ? MLDerivedSearchHit(uid: uid, matchedTokenCount: query.count)
                    : nil
            }
            .sorted { Self.uidOrder($0.uid, $1.uid) }
            .prefix(limit)
            .map { $0 }
        }
    }

    public func hasIndexedEntries(for key: MLPipelineExecutionKey) -> Bool {
        lock.withLock {
            records.contains { storedKey, record in
                storedKey.accountIdentifier == key.accountIdentifier
                    && key.artifacts.contains(record.artifact)
                    && record.state == .completed
                    && !(record.output?.normalizedSearchTokens.isEmpty ?? true)
            }
        }
    }

    @discardableResult
    public func reconcile(liveUIDs: Set<PhotoUID>, for key: MLPipelineExecutionKey) -> Bool {
        lock.withLock {
            let staleKeys = records.compactMap { storedKey, record in
                storedKey.accountIdentifier == key.accountIdentifier
                    && key.artifacts.contains(record.artifact)
                    && !liveUIDs.contains(storedKey.uid)
                    ? storedKey
                    : nil
            }
            guard !staleKeys.isEmpty else { return true }
            for staleKey in staleKeys { records.removeValue(forKey: staleKey) }
            bumpGeneration(key)
            return true
        }
    }

    public func purge(artifact: MLDerivedArtifactIdentity, accountIdentifier: String) {
        lock.withLock {
            records = records.filter {
                $0.key.accountIdentifier != accountIdentifier || $0.value.artifact != artifact
            }
        }
    }

    public func purge(pipelineID: MLPipelineID, accountIdentifier: String) {
        lock.withLock {
            records = records.filter {
                $0.key.accountIdentifier != accountIdentifier || $0.value.artifact.pipelineID != pipelineID
            }
        }
    }

    private func bumpGeneration(_ key: MLPipelineExecutionKey) {
        generations[generationKey(key), default: 0] &+= 1
    }

    private func generationKey(_ key: MLPipelineExecutionKey) -> String {
        let namespaces = key.artifacts.map(\.stableNamespace).sorted().joined(separator: "|")
        return "\(key.accountIdentifier)|\(key.pipelineID.rawValue)|\(key.schemaVersion)|\(namespaces)"
    }

    private static func workOrder(_ lhs: MLDerivedPipelineWorkItem, _ rhs: MLDerivedPipelineWorkItem) -> Bool {
        if lhs.asset.uid != rhs.asset.uid { return uidOrder(lhs.asset.uid, rhs.asset.uid) }
        return lhs.artifact.stableNamespace < rhs.artifact.stableNamespace
    }

    private static func uidOrder(_ lhs: PhotoUID, _ rhs: PhotoUID) -> Bool {
        lhs.volumeID != rhs.volumeID ? lhs.volumeID < rhs.volumeID : lhs.nodeID < rhs.nodeID
    }
}
