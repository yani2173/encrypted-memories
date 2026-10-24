import CryptoKit
import Foundation
import PhotosCore

/// Byte transport for one artifact download. Implementations (URLSession in the Apple adapter,
/// scripted fakes in tests) write the complete artifact to `destination`, reporting progress as
/// `(bytesReceived, expectedTotalBytes?)`. They may resume a partial file already present at
/// `destination`; correctness never depends on it because the installer verifies size and
/// SHA-256 before any byte becomes visible to the model loader.
public protocol MLModelArtifactTransport: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws
}

public enum MLModelInstallError: Error, Equatable {
    case unsafeArtifactPath(String)
    case sizeMismatch(artifact: String, expected: Int64, actual: Int64)
    case checksumMismatch(artifact: String)
    case artifactMissing(String)
    case ambiguousModelArtifact
    case installRecordUnreadable
    case notDownloadable
    /// The entry's weight license forbids redistribution or product use; downloading it into
    /// a user installation is technically blocked, whatever the catalog data says elsewhere.
    case licenseProhibitsDistribution
    /// The volume has less free space than the remaining download plus a reserve for the system.
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case cancelled
}

/// Durable record written into an install directory after every artifact verified. Its presence
/// (with matching specs) is the definition of "installed"; a directory without it is garbage
/// from an interrupted install and gets cleaned up.
public struct MLModelInstallCompatibility: Sendable, Hashable, Codable {
    public let compatibilityKey: String?
    public let role: MLModelRole
    public let capabilities: [MLModelCapability]
    public let sourceRevision: String?
    public let descriptor: MLModelDescriptor
    public let tokenizerID: String
    public let preprocessingID: String
    public let runtimeContract: MLModelRuntimeContract
    public let runtimeResourcePaths: [String]
    public let license: MLModelLicense
    public let releaseTrack: MLModelReleaseTrack

    public init(entry: MLModelCatalogEntry) {
        self.compatibilityKey = entry.compatibilityKey
        self.role = entry.role
        self.capabilities = entry.capabilities.sorted { $0.rawValue < $1.rawValue }
        self.sourceRevision = entry.sourceRevision
        self.descriptor = entry.descriptor
        self.tokenizerID = entry.tokenizerID
        self.preprocessingID = entry.preprocessingID
        self.runtimeContract = entry.runtimeContract
        self.runtimeResourcePaths = entry.runtimeResourcePaths
        self.license = entry.license
        self.releaseTrack = entry.releaseTrack
    }
}

public struct MLModelInstallRecord: Sendable, Equatable, Codable {
    public let modelID: MLModelID
    public let revision: String
    public let compatibility: MLModelInstallCompatibility
    public let modelRootPath: String
    public let artifacts: [MLModelArtifactSpec]
    public let installedByteCount: Int64
    public let installedAt: Date

    public init(
        modelID: MLModelID,
        revision: String,
        compatibility: MLModelInstallCompatibility,
        modelRootPath: String,
        artifacts: [MLModelArtifactSpec],
        installedByteCount: Int64,
        installedAt: Date
    ) {
        self.modelID = modelID
        self.revision = revision
        self.compatibility = compatibility
        self.modelRootPath = modelRootPath
        self.artifacts = artifacts
        self.installedByteCount = installedByteCount
        self.installedAt = installedAt
    }
}

/// A verified, activated installation the runtime may load.
public struct MLInstalledModel: Sendable, Equatable {
    public let entry: MLModelCatalogEntry
    public let record: MLModelInstallRecord
    /// Directory containing the verified artifacts.
    public let installDirectory: URL
    /// Directory for generated runtime files. These files are rebuilt before each activation.
    public let runtimeCacheDirectory: URL

    public init(
        entry: MLModelCatalogEntry,
        record: MLModelInstallRecord,
        installDirectory: URL,
        runtimeCacheDirectory: URL
    ) {
        self.entry = entry
        self.record = record
        self.installDirectory = installDirectory
        self.runtimeCacheDirectory = runtimeCacheDirectory
    }
}

/// Download/verify/install progress for one model, coalesced for UI.
public struct MLModelTransferProgress: Sendable, Equatable {
    public var bytesReceived: Int64
    public var totalBytes: Int64?

    public init(bytesReceived: Int64 = 0, totalBytes: Int64? = nil) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

/// Downloads, verifies and atomically installs model artifacts.
///
/// Guarantees:
/// - **Verified before visible.** Every artifact's size and SHA-256 must match its pinned spec
///   before the staging directory is promoted; the install directory either contains a complete
///   verified set plus `install.json`, or it does not exist.
/// - **Idempotent.** Installing an already-installed `(model, revision)` returns immediately.
/// - **Restart-safe.** Partial downloads live beside their staging destination and resume in
///   place. Nothing in `tmp/` is ever loaded.
/// - **Single-flight.** Concurrent install requests for the same model await one task.
/// - **Traversal-proof.** Artifact relative paths are validated before any filesystem use.
public actor MLModelInstaller {
    private struct InstallRequestKey: Hashable {
        let compatibility: MLModelInstallCompatibility
        let artifacts: [MLModelArtifactSpec]
    }

    private struct InstallDestinationKey: Hashable {
        let modelID: MLModelID
        let revision: String
    }

    private struct InFlightInstall {
        let token = UUID()
        let requestKey: InstallRequestKey
        let task: Task<MLModelInstallRecord, Error>
    }

    private let layout: MLModelInstallLayout
    private let transport: any MLModelArtifactTransport
    private let now: @Sendable () -> Date
    private let availableCapacity: @Sendable (URL) -> Int64?
    private var inFlight: [InstallDestinationKey: InFlightInstall] = [:]
    private var modelFenceOwners: [MLModelID: Int] = [:]
    private var allInstallFenceOwners = 0

    #if DEBUG
        private var installWaiterCount = 0
        private var installWaiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var fenceWaiters:
            [(minimum: Int, modelID: MLModelID?, continuation: CheckedContinuation<Void, Never>)] = []
    #endif

    /// Free space the installer leaves untouched, so the system, the photo cache and the search index
    /// keep room to work after a model download.
    public static let storageReserveBytes: Int64 = 256 * 1024 * 1024

    public init(
        layout: MLModelInstallLayout,
        transport: any MLModelArtifactTransport,
        now: @escaping @Sendable () -> Date = { Date() },
        availableCapacity: @escaping @Sendable (URL) -> Int64? = DeviceStorage.availableCapacity(at:)
    ) {
        self.layout = layout
        self.transport = transport
        self.now = now
        self.availableCapacity = availableCapacity
    }

    /// The verified installation for `entry` at `revision`, or `nil` when none exists.
    /// Never trusts a directory without a matching, fully verifiable `install.json`.
    public nonisolated func installedRecord(for entry: MLModelCatalogEntry, revision: String) -> MLModelInstallRecord? {
        let expectedArtifacts: [MLModelArtifactSpec]?
        if let plan = entry.downloadPlan {
            guard plan.revision == revision else { return nil }
            expectedArtifacts = plan.items.map(\.artifact)
        } else {
            expectedArtifacts = nil
        }
        return Self.readVerifiedRecord(
            at: layout.installRecordURL(for: entry.id, revision: revision),
            expecting: entry.id,
            revision: revision,
            compatibility: MLModelInstallCompatibility(entry: entry),
            expectedArtifacts: expectedArtifacts,
            installDirectory: layout.installDirectory(for: entry.id, revision: revision)
        )
    }

    /// Any verified installation for `entry`, regardless of revision (newest first).
    public nonisolated func anyInstalledRecord(for entry: MLModelCatalogEntry) -> MLModelInstallRecord? {
        if let plan = entry.downloadPlan {
            return installedRecord(for: entry, revision: plan.revision)
        }
        let modelDir = layout.modelDirectory(for: entry.id)
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path) else { return nil }
        return
            revisions
            .compactMap { revision in
                Self.readVerifiedRecord(
                    at: layout.installRecordURL(for: entry.id, revision: revision),
                    expecting: entry.id,
                    revision: revision,
                    compatibility: MLModelInstallCompatibility(entry: entry),
                    expectedArtifacts: nil,
                    installDirectory: layout.installDirectory(for: entry.id, revision: revision)
                )
            }
            .max { $0.installedAt < $1.installedAt }
    }

    /// Download and install `entry` from its pinned plan. Progress covers download bytes only;
    /// verification/installation are separate lifecycle phases.
    public func install(
        _ entry: MLModelCatalogEntry,
        onProgress: @escaping @Sendable (MLModelTransferProgress) async -> Void
    ) async throws -> MLModelInstallRecord {
        try Task.checkCancellation()
        guard let plan = entry.downloadPlan else { throw MLModelInstallError.notDownloadable }
        // The transfer boundary enforces the distribution and product-use license flags.
        guard entry.license.allowsRedistribution, entry.license.allowsProductUse else {
            throw MLModelInstallError.licenseProhibitsDistribution
        }

        let requestKey = InstallRequestKey(
            compatibility: MLModelInstallCompatibility(entry: entry),
            artifacts: plan.items.map(\.artifact).sorted { $0.relativePath < $1.relativePath }
        )
        let destinationKey = InstallDestinationKey(modelID: entry.id, revision: plan.revision)
        guard !isFenced(entry.id) else {
            throw MLModelInstallError.cancelled
        }

        while true {
            guard !isFenced(entry.id) else {
                throw MLModelInstallError.cancelled
            }
            if let existing = inFlight[destinationKey] {
                #if DEBUG
                    beginInstallWaiter()
                    defer { endInstallWaiter() }
                #endif
                let record = try await existing.task.value
                guard !isFenced(entry.id) else {
                    throw MLModelInstallError.cancelled
                }
                if existing.requestKey == requestKey {
                    return record
                }
                if inFlight[destinationKey]?.token == existing.token {
                    inFlight[destinationKey] = nil
                }
                continue
            }
            if let installed = installedRecord(for: entry, revision: plan.revision) {
                return installed
            }

            try Task.checkCancellation()
            let layout = self.layout
            let transport = self.transport
            let now = self.now
            let availableCapacity = self.availableCapacity
            let install = InFlightInstall(
                requestKey: requestKey,
                task: Task {
                    try await Self.performInstall(
                        entry: entry,
                        plan: plan,
                        layout: layout,
                        transport: transport,
                        now: now,
                        availableCapacity: availableCapacity,
                        onProgress: onProgress
                    )
                })
            inFlight[destinationKey] = install
            // Clear only our entry: a cancel + fresh install may have replaced it while we awaited.
            defer {
                if inFlight[destinationKey]?.token == install.token {
                    inFlight[destinationKey] = nil
                }
            }
            return try await install.task.value
        }
    }

    /// Install `entry` by copying a developer-provided local artifact directory. Checksums are
    /// computed from the local content (there is no pinned upstream), so the install record
    /// stays self-verifying. Revision is derived from the content hashes.
    public func installFromLocalArtifact(
        _ entry: MLModelCatalogEntry,
        artifactDirectory: URL
    ) async throws -> MLModelInstallRecord {
        let fm = FileManager.default
        guard fm.fileExists(atPath: artifactDirectory.path) else {
            throw MLModelInstallError.artifactMissing(artifactDirectory.lastPathComponent)
        }
        var specs: [MLModelArtifactSpec] = []
        let files = try Self.localInstallFiles(for: entry, under: artifactDirectory)
        guard !files.isEmpty else { throw MLModelInstallError.artifactMissing(artifactDirectory.lastPathComponent) }
        for relativePath in files.sorted() {
            guard MLModelInstallLayout.isSafeRelativePath(relativePath) else {
                throw MLModelInstallError.unsafeArtifactPath(relativePath)
            }
            let fileURL = artifactDirectory.appendingPathComponent(relativePath)
            let digest = try Self.sha256Hex(of: fileURL)
            let size = try Self.fileSize(of: fileURL)
            specs.append(MLModelArtifactSpec(relativePath: relativePath, sha256: digest, byteCount: size))
        }
        // Deterministic content revision: hash of the sorted per-file hashes.
        let combined = specs.map { "\($0.relativePath):\($0.sha256)" }.joined(separator: "\n")
        let revision =
            "local-"
            + SHA256.hash(data: Data(combined.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16)

        if let installed = installedRecord(for: entry, revision: String(revision)) {
            return installed
        }

        let staging = layout.stagingDirectory(for: entry.id, revision: String(revision))
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for spec in specs {
            let destination = staging.appendingPathComponent(spec.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: artifactDirectory.appendingPathComponent(spec.relativePath), to: destination)
        }
        return try Self.promote(
            staging: staging,
            entry: entry,
            revision: String(revision),
            specs: specs,
            layout: layout,
            installedAt: now()
        )
    }

    /// Remove every installed and partial revision of `entry` (used after model switches).
    /// Awaits any in-flight install of the same entry first, so a racing installer task can
    /// never recreate files after the removal.
    public func uninstall(_ entry: MLModelCatalogEntry) async {
        acquireModelFence(for: entry.id)
        defer { releaseModelFence(for: entry.id) }
        await cancelRegisteredInstalls(for: entry.id)
        try? FileManager.default.removeItem(at: layout.modelDirectory(for: entry.id))
        try? FileManager.default.removeItem(at: layout.runtimeCacheModelDirectory(for: entry.id))
        for staging in layout.stagingDirectories(for: entry.id) {
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// Removes superseded verified revisions after a replacement session is active.
    public func removeInstalledRevisions(of id: MLModelID, keeping revision: String) {
        let fm = FileManager.default
        let modelDirectory = layout.modelDirectory(for: id)
        if let revisions = try? fm.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for directory in revisions where directory.lastPathComponent != revision {
                try? fm.removeItem(at: directory)
            }
        }
        let cacheDirectory = layout.runtimeCacheModelDirectory(for: id)
        if let revisions = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for directory in revisions where directory.lastPathComponent != revision {
                try? fm.removeItem(at: directory)
            }
        }
    }

    /// Cancels an active installation and waits for its task to finish.
    /// Awaiting matters: callers (shutdown, purge) delete the install root next, and a
    /// still-running install task would otherwise recreate `tmp/` after the delete. Partial
    /// downloads stay in `tmp/` for a later resume/restart; they are never loadable.
    public func cancelInstall(of id: MLModelID) async {
        acquireModelFence(for: id)
        defer { releaseModelFence(for: id) }
        await cancelRegisteredInstalls(for: id)
    }

    private func cancelRegisteredInstalls(for id: MLModelID? = nil) async {
        let installs = inFlight.filter { key, _ in
            guard let id else { return true }
            return key.modelID == id
        }
        for install in installs.values { install.task.cancel() }
        for install in installs.values { _ = try? await install.task.value }
        let cancelledTokens = Set(installs.values.map(\.token))
        inFlight = inFlight.filter { !cancelledTokens.contains($0.value.token) }
    }

    /// Cancel and await every in-flight install (session shutdown / purge).
    public func cancelAllInstalls() async {
        allInstallFenceOwners += 1
        #if DEBUG
            resumeSatisfiedFenceWaiters()
        #endif
        defer { allInstallFenceOwners -= 1 }
        await cancelRegisteredInstalls()
    }

    private func isFenced(_ id: MLModelID) -> Bool {
        allInstallFenceOwners > 0 || (modelFenceOwners[id] ?? 0) > 0
    }

    private func acquireModelFence(for id: MLModelID) {
        modelFenceOwners[id, default: 0] += 1
        #if DEBUG
            resumeSatisfiedFenceWaiters()
        #endif
    }

    private func releaseModelFence(for id: MLModelID) {
        guard let owners = modelFenceOwners[id], owners > 0 else {
            preconditionFailure("released an unowned model-install fence")
        }
        if owners == 1 {
            modelFenceOwners[id] = nil
        } else {
            modelFenceOwners[id] = owners - 1
        }
        #if DEBUG
            resumeSatisfiedFenceWaiters()
        #endif
    }

    #if DEBUG
        /// Test-only synchronization for admission tests. This observes actor state instead of
        /// using scheduler turns as a proxy for a caller reaching an awaited predecessor.
        internal func waitForInstallWaiters(_ minimum: Int) async {
            guard installWaiterCount < minimum else { return }
            await withCheckedContinuation { continuation in
                installWaiters.append((minimum: minimum, continuation: continuation))
            }
        }

        /// Test-only synchronization for overlapping cancellation/uninstall owners.
        internal func waitForFenceOwners(modelID: MLModelID? = nil, minimum: Int) async {
            guard fenceOwnerCount(for: modelID) < minimum else { return }
            await withCheckedContinuation { continuation in
                fenceWaiters.append((minimum: minimum, modelID: modelID, continuation: continuation))
            }
        }

        private func beginInstallWaiter() {
            installWaiterCount += 1
            resumeSatisfiedFenceWaiters()
        }

        private func endInstallWaiter() {
            installWaiterCount -= 1
        }

        private func fenceOwnerCount(for modelID: MLModelID?) -> Int {
            if let modelID {
                return allInstallFenceOwners + (modelFenceOwners[modelID] ?? 0)
            }
            return allInstallFenceOwners
        }

        private func resumeSatisfiedFenceWaiters() {
            var remainingInstallWaiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in installWaiters {
                if installWaiterCount >= waiter.minimum {
                    waiter.continuation.resume()
                } else {
                    remainingInstallWaiters.append(waiter)
                }
            }
            installWaiters = remainingInstallWaiters

            var remaining: [(minimum: Int, modelID: MLModelID?, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in fenceWaiters {
                let satisfied = fenceOwnerCount(for: waiter.modelID) >= waiter.minimum
                if satisfied {
                    waiter.continuation.resume()
                } else {
                    remaining.append(waiter)
                }
            }
            fenceWaiters = remaining
        }
    #endif

    // MARK: - Install pipeline (static: no actor hops during I/O)

    private static func performInstall(
        entry: MLModelCatalogEntry,
        plan: MLModelDownloadPlan,
        layout: MLModelInstallLayout,
        transport: any MLModelArtifactTransport,
        now: @Sendable () -> Date,
        availableCapacity: @Sendable (URL) -> Int64?,
        onProgress: @escaping @Sendable (MLModelTransferProgress) async -> Void
    ) async throws -> MLModelInstallRecord {
        let fm = FileManager.default
        for item in plan.items where !MLModelInstallLayout.isSafeRelativePath(item.artifact.relativePath) {
            throw MLModelInstallError.unsafeArtifactPath(item.artifact.relativePath)
        }
        try fm.createDirectory(at: layout.temporaryDirectory, withIntermediateDirectories: true)

        // Download directly into the staging tree. Keeping one resumable partial beside its
        // final path avoids the previous full-size temp-file + staging-copy peak.
        let totalBytes = plan.totalByteCount
        var completedBytes: Int64 = 0
        let staging = layout.stagingDirectory(for: entry.id, revision: plan.revision)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        // The app can stop after the atomic record write, before the directory rename.
        // Reuse the installed-record verifier; a marker alone never authorizes model loading.
        if try fm.contentsOfDirectory(atPath: staging.path).contains(MLModelInstallLayout.installRecordFileName) {
            if let record = readVerifiedRecord(
                at: staging.appendingPathComponent(MLModelInstallLayout.installRecordFileName),
                expecting: entry.id,
                revision: plan.revision,
                compatibility: MLModelInstallCompatibility(entry: entry),
                expectedArtifacts: plan.items.map(\.artifact),
                installDirectory: staging
            ) {
                try Task.checkCancellation()
                return try promote(
                    staging: staging,
                    entry: entry,
                    revision: plan.revision,
                    specs: plan.items.map(\.artifact),
                    layout: layout,
                    installedAt: record.installedAt,
                    recoveredRecord: record
                )
            }
            // A failed verification invalidates the whole recorded install, including partials.
            // Propagate deletion errors so a retry cannot silently keep the poisoned tree.
            try fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        // Resumed bytes already occupy the disk; only the rest of the transfer needs new space.
        let remainingBytes = plan.items.reduce(Int64(0)) { total, item in
            let destination = staging.appendingPathComponent(item.artifact.relativePath)
            let present = max(
                (try? fileSize(of: destination)) ?? 0,
                (try? fileSize(of: destination.appendingPathExtension("partial"))) ?? 0
            )
            return total + max(0, item.artifact.byteCount - present)
        }
        let requiredBytes = remainingBytes + storageReserveBytes
        func insufficientStorage() -> MLModelInstallError? {
            guard let available = availableCapacity(staging), available < requiredBytes else { return nil }
            return .insufficientStorage(requiredBytes: requiredBytes, availableBytes: available)
        }
        if remainingBytes > 0, let failure = insufficientStorage() {
            throw failure
        }
        for item in plan.items {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(item.artifact.relativePath)
            let partial = destination.appendingPathExtension("partial")
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            if verifyFile(at: destination, against: item.artifact) != nil {
                // An interrupted promotion may have left a complete verified partial.
                if verifyFile(at: partial, against: item.artifact) == nil {
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: partial, to: destination)
                } else {
                    if (try? fileSize(of: partial)) == item.artifact.byteCount {
                        try? fm.removeItem(at: partial)
                    }
                    let base = completedBytes
                    do {
                        try await transport.download(
                            from: item.url,
                            to: partial,
                            expectedByteCount: item.artifact.byteCount
                        ) { received, _ in
                            await onProgress(
                                MLModelTransferProgress(bytesReceived: base + received, totalBytes: totalBytes))
                        }
                    } catch is CancellationError {
                        throw MLModelInstallError.cancelled
                    } catch {
                        // A full disk surfaces through several URLSession and POSIX error shapes.
                        // Measure again instead of guessing from the error.
                        throw insufficientStorage() ?? error
                    }
                    if let failure = verifyFile(at: partial, against: item.artifact) {
                        // A completed but invalid transfer must not poison future resumes.
                        try? fm.removeItem(at: partial)
                        throw failure
                    }
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: partial, to: destination)
                }
            }
            completedBytes += item.artifact.byteCount
            await onProgress(MLModelTransferProgress(bytesReceived: completedBytes, totalBytes: totalBytes))
        }

        try Task.checkCancellation()
        for item in plan.items {
            let destination = staging.appendingPathComponent(item.artifact.relativePath)
            if let failure = verifyFile(at: destination, against: item.artifact) {
                throw failure
            }
            try? fm.removeItem(at: destination.appendingPathExtension("partial"))
        }

        return try promote(
            staging: staging,
            entry: entry,
            revision: plan.revision,
            specs: plan.items.map(\.artifact),
            layout: layout,
            installedAt: now()
        )
    }

    /// Atomically promote a fully verified staging directory into the install location and
    /// stamp it with its install record. The rename is the transaction point.
    private static func promote(
        staging: URL,
        entry: MLModelCatalogEntry,
        revision: String,
        specs: [MLModelArtifactSpec],
        layout: MLModelInstallLayout,
        installedAt: Date,
        recoveredRecord: MLModelInstallRecord? = nil
    ) throws -> MLModelInstallRecord {
        let fm = FileManager.default
        let normalizedSpecs = specs.sorted { $0.relativePath < $1.relativePath }
        guard let modelRootPath = modelRootPath(in: normalizedSpecs) else {
            throw MLModelInstallError.ambiguousModelArtifact
        }
        let installedPaths = Set(normalizedSpecs.map(\.relativePath))
        let permittedSidecars = Set(entry.runtimeResourcePaths)
        guard
            installedPaths.allSatisfy({ path in
                path == modelRootPath
                    || path.hasPrefix(modelRootPath + "/")
                    || permittedSidecars.contains(path)
            }),
            permittedSidecars.isSubset(of: installedPaths),
            validateInstallTree(
                at: staging,
                artifacts: normalizedSpecs,
                includesInstallRecord: recoveredRecord != nil
            )
        else {
            throw MLModelInstallError.ambiguousModelArtifact
        }
        let record =
            recoveredRecord
            ?? MLModelInstallRecord(
                modelID: entry.id,
                revision: revision,
                compatibility: MLModelInstallCompatibility(entry: entry),
                modelRootPath: modelRootPath,
                artifacts: normalizedSpecs,
                installedByteCount: normalizedSpecs.reduce(0) { $0 + $1.byteCount },
                installedAt: installedAt
            )
        if recoveredRecord == nil {
            let recordData = try JSONEncoder().encode(record)
            try recordData.write(
                to: staging.appendingPathComponent(MLModelInstallLayout.installRecordFileName), options: .atomic)
        }
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            UpgradeTestProbe.checkpoint("model.installRecord")
        #endif

        guard
            validateInstallTree(
                at: staging,
                artifacts: normalizedSpecs,
                includesInstallRecord: true
            )
        else {
            throw MLModelInstallError.installRecordUnreadable
        }

        let installDir = layout.installDirectory(for: entry.id, revision: revision)
        try fm.createDirectory(at: installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: installDir)
        try fm.moveItem(at: staging, to: installDir)
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            UpgradeTestProbe.checkpoint("model.promoted")
        #endif

        return record
    }

    /// `nil` when the file matches the spec; otherwise the error describing the mismatch.
    private static func verifyFile(at url: URL, against spec: MLModelArtifactSpec) -> MLModelInstallError? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            return .artifactMissing(spec.relativePath)
        }
        guard let size = try? fileSize(of: url), size == spec.byteCount else {
            return .sizeMismatch(
                artifact: spec.relativePath,
                expected: spec.byteCount,
                actual: (try? fileSize(of: url)) ?? -1
            )
        }
        guard let digest = try? sha256Hex(of: url), digest == spec.sha256 else {
            return .checksumMismatch(artifact: spec.relativePath)
        }
        return nil
    }

    private static func readVerifiedRecord(
        at recordURL: URL,
        expecting id: MLModelID,
        revision: String,
        compatibility: MLModelInstallCompatibility,
        expectedArtifacts: [MLModelArtifactSpec]?,
        installDirectory: URL
    ) -> MLModelInstallRecord? {
        guard let data = try? Data(contentsOf: recordURL),
            let record = try? JSONDecoder().decode(MLModelInstallRecord.self, from: data),
            record.modelID == id,
            record.revision == revision,
            record.compatibility == compatibility,
            !record.artifacts.isEmpty,
            Set(record.artifacts.map(\.relativePath)).count == record.artifacts.count,
            record.artifacts.allSatisfy({ artifact in
                MLModelInstallLayout.isSafeRelativePath(artifact.relativePath)
                    && artifact.sha256.count == 64
                    && artifact.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
                    && artifact.byteCount > 0
            }),
            record.installedByteCount == record.artifacts.reduce(Int64(0), { $0 + $1.byteCount }),
            record.modelRootPath == modelRootPath(in: record.artifacts),
            expectedArtifacts.map({
                $0.sorted { $0.relativePath < $1.relativePath } == record.artifacts
            }) ?? true,
            validateInstallTree(
                at: installDirectory,
                artifacts: record.artifacts,
                includesInstallRecord: true
            )
        else { return nil }
        for artifact in record.artifacts {
            let url = installDirectory.appendingPathComponent(artifact.relativePath)
            guard verifyFile(at: url, against: artifact) == nil else { return nil }
        }
        return record
    }

    private static func modelRootPath(in artifacts: [MLModelArtifactSpec]) -> String? {
        let roots = Set(
            artifacts.compactMap { artifact -> String? in
                let component = artifact.relativePath.split(separator: "/", maxSplits: 1).first.map(String.init)
                guard let component,
                    component.lowercased().hasSuffix(".mlmodelc")
                        || component.lowercased().hasSuffix(".mlpackage")
                else { return nil }
                return component
            })
        guard roots.count == 1, let root = roots.first,
            artifacts.contains(where: { $0.relativePath.hasPrefix(root + "/") })
        else {
            return nil
        }
        return root
    }

    private static func validateInstallTree(
        at root: URL,
        artifacts: [MLModelArtifactSpec],
        includesInstallRecord: Bool
    ) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let rootValues = try? root.resourceValues(forKeys: keys),
            rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true
        else { return false }

        var expectedFiles = Set(artifacts.map(\.relativePath))
        if includesInstallRecord {
            expectedFiles.insert(MLModelInstallLayout.installRecordFileName)
        }
        var expectedDirectories: Set<String> = []
        for path in expectedFiles {
            var components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { return false }
            components.removeLast()
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                expectedDirectories.insert(prefix)
            }
        }

        var observedFiles: Set<String> = []
        var observedDirectories: Set<String> = []
        var readFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in
                    readFailed = true
                    return false
                }
            )
        else { return false }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isSymbolicLink != true
            else { return false }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { return false }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            if values.isRegularFile == true {
                observedFiles.insert(relativePath)
            } else if values.isDirectory == true {
                observedDirectories.insert(relativePath)
            } else {
                return false
            }
        }
        return !readFailed
            && observedFiles == expectedFiles
            && observedDirectories == expectedDirectories
    }

    // MARK: - File helpers

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int64) ?? Int64((attributes[.size] as? Int) ?? 0)
    }

    private static func localInstallFiles(for entry: MLModelCatalogEntry, under root: URL) throws -> [String] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let modelRoots = contents.filter { url in
            guard ["mlmodelc", "mlpackage"].contains(url.pathExtension.lowercased()),
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard modelRoots.count == 1, let modelRoot = modelRoots.first else {
            if modelRoots.isEmpty { throw MLModelInstallError.artifactMissing("*.mlmodelc or *.mlpackage") }
            throw MLModelInstallError.ambiguousModelArtifact
        }

        var paths: [String] = []
        let rootPath = root.standardizedFileURL.path
        guard
            let enumerator = fm.enumerator(
                at: modelRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        else {
            throw MLModelInstallError.artifactMissing(modelRoot.lastPathComponent)
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MLModelInstallError.unsafeArtifactPath(fileURL.lastPathComponent)
            }
            guard values.isRegularFile == true else { continue }
            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(fullPath.dropFirst(rootPath.count + 1)))
        }
        for relativePath in entry.runtimeResourcePaths {
            guard MLModelInstallLayout.isSafeRelativePath(relativePath) else {
                throw MLModelInstallError.unsafeArtifactPath(relativePath)
            }
            let fileURL = root.appendingPathComponent(relativePath)
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw MLModelInstallError.artifactMissing(relativePath)
            }
            paths.append(relativePath)
        }
        return paths
    }
}
