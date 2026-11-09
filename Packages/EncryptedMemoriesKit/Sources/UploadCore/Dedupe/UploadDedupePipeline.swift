import Foundation
import PhotosCore

/// Universal pre-upload pipeline: manifest-backed hashing, Proton identity, batched duplicate lookup,
/// and `UploadDuplicateDecisionPolicy`. Platform adapters supply only `UploadResourceDescriptor`s.
/// Cached identities, coalesced lookups, and bounded batches avoid duplicate work.
public actor UploadDedupePipeline: UploadIdentityResolving {
    /// Maximum number of name hashes in one duplicate request.
    public static let protonDuplicateBatchSize = 150
    private static let primeLookupConcurrency = 3
    /// A root reads its same-content rows in one consistent query, so related files listed first hide no main photo,
    /// and weighs them in batches: each batch costs at most one visibility read, only for links outside the cache.
    /// The bound keeps a pathological library cheap: past 256 rows the root uploads as its own photo.
    static let rootMatchBatchSize = 8
    static let rootMatchBound = 256
    /// How long the state that `prime` read for a name row proves a copy. Another device can trash the copy after
    /// that read; an older answer is read again before a name row counts as a backup, like an index row (#553).
    static let primedStateLifetime: TimeInterval = 15

    private let store: any UploadIdentityStore
    private let hasher: any UploadHashing
    private let checker: any UploadDuplicateChecking
    private let resourceCoordinator: LibraryResourceCoordinator
    private let currentClientUID: String?
    private let batchSize: Int
    private let replacementJournal: (any EditReplacementJournaling)?
    private let now: @Sendable () -> Date
    private struct RestoredCheck: Sendable {
        let context: UploadRestoredCompoundContext
        let isCurrent: @Sendable () -> Bool
    }
    private var restoredChecks: [UploadSourceIdentity: RestoredCheck] = [:]

    /// Per-batch remote view from each name hash to matching remote items.
    private var duplicateCache: [String: [RemotePhotoDuplicate]] = [:]
    /// In-flight lookups, one entry per name hash, so concurrent items never double-query.
    private var inFlight: [String: Task<[String: [RemotePhotoDuplicate]], any Error>] = [:]
    /// Bumped by `invalidateCachedRemoteState` so lookups that were already in flight when the
    /// view was invalidated cannot repopulate the cache with pre-invalidation data.
    private var cacheGeneration = 0
    /// The role of each link that a root asked about in this view: `rootVisibility` holds the answers, and
    /// `rootVisibilityAsked` also holds the links that the server no longer names or whose read failed.
    /// `prime` fills both in batches, so a resolve normally reads no visibility itself.
    private var rootVisibility: [String: RemoteLinkVisibility] = [:]
    private var rootVisibilityAsked: Set<String> = []
    /// When a complete read answered for each link in `rootVisibility`, also for a link that the answer left out.
    private var rootVisibilityReadAt: [String: Date] = [:]
    /// The primed links in the order of the upcoming roots, so a refresh reads the next ones in the same request.
    private var rootVisibilityOrder: [String] = []
    private var rootVisibilityPositions: [String: Int] = [:]
    /// Refreshes in flight, one entry per link, so resolves at the same time share one read.
    private var stateRefreshes: [String: Task<[String: RemoteLinkVisibility], any Error>] = [:]
    /// `prime` is nonthrowing. Defer cancellation only to the source identities in its batch.
    /// Other callers share this pipeline and must not inherit a stopped batch's cancellation.
    /// Ordinary prefetch errors remain best effort. An explicit view invalidation permits a fresh retry.
    private var primingCancellation: (error: any Error, sources: Set<UploadSourceIdentity>)?

    /// Same-run content coalescing: one claim per (key epoch | content hash) while an `.upload`
    /// decision is outstanding. Identical bytes discovered concurrently (copied folders in one
    /// scan, duplicate files in one enqueue) wait here until the first upload settles, then
    /// re-check the manifest instead of uploading the same content in parallel.
    private struct PendingUpload {
        // Different revisions of one resource may resolve concurrently. Use the same fingerprint as
        // manifest reuse so settling an older revision cannot release the newer revision's claims.
        let owner: UploadIdentityRecord
        var waiters: [UUID: CheckedContinuation<Void, any Error>]
    }

    private var pendingContentUploads: [String: PendingUpload] = [:]
    /// The server draft is keyed by the encrypted/corrected name. Different photos can legally
    /// share a camera filename, but they must not upload under that name concurrently: otherwise
    /// one live upload can look exactly like a stale same-client draft to the other.
    private var pendingNameUploads: [String: PendingUpload] = [:]

    private static func contentKey(epoch: String, contentHash: String) -> String {
        "\(epoch)|\(contentHash)"
    }

    private static func nameKey(epoch: String, nameHash: String) -> String {
        "\(epoch)|\(nameHash)"
    }

    public init(
        store: any UploadIdentityStore,
        hasher: any UploadHashing = UploadFileHasher(),
        checker: any UploadDuplicateChecking,
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        currentClientUID: String? = nil,
        batchSize: Int = UploadDedupePipeline.protonDuplicateBatchSize,
        replacementJournal: (any EditReplacementJournaling)? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.hasher = hasher
        self.checker = checker
        self.resourceCoordinator = resourceCoordinator
        self.currentClientUID = currentClientUID
        self.batchSize = max(1, batchSize)
        self.replacementJournal = replacementJournal
        self.now = now
    }

    // MARK: - UploadIdentityResolving

    public func prepareRestoredCompound(
        _ context: UploadRestoredCompoundContext, isCurrent: @escaping @Sendable () -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard context.source.resource == .primary, isCurrent() else { throw CancellationError() }
        restoredChecks[context.source] = RestoredCheck(context: context, isCurrent: isCurrent)
    }

    public func endRestoredCompound(_ context: UploadRestoredCompoundContext) async {
        if restoredChecks[context.source]?.context == context { restoredChecks.removeValue(forKey: context.source) }
    }

    public func restoredPhotoOutcome(
        _ context: UploadRestoredCompoundContext
    ) async throws -> PendingBackupReturnOutcome {
        guard let check = restoredChecks[context.source], check.context == context, check.isCurrent() else {
            return .unreadable
        }
        let members = context.requiredMembers.map { resource in
            store.record(
                for: UploadSourceIdentity(
                    kind: context.source.kind, identifier: context.source.identifier, resource: resource))?.remoteLinkID
        }
        let read = try await checker.linkVisibility(
            of: Array(Set([context.confirmedRemote.nodeID] + members.compactMap { $0 })).sorted())
        try Task.checkCancellation()
        guard check.isCurrent(), restoredChecks[context.source]?.context == context,
            let state = read[context.confirmedRemote.nodeID], state.hasExplicitPhotoState
        else { return .unreadable }
        guard state.isActiveMain else { return state.trashTime != nil ? .remoteTrashed : .unreadable }
        guard
            members.allSatisfy({ link in
                guard let link, let member = read[link] else { return false }
                return member.hasExplicitPhotoState && member.isActive
                    && member.mainPhotoLinkID == context.confirmedRemote.nodeID
            })
        else { return .waiting(until: now().addingTimeInterval(60)) }
        return .completed
    }

    @discardableResult
    private func restoredCheck(for descriptor: UploadResourceDescriptor) throws -> RestoredCheck? {
        let source = UploadSourceIdentity(kind: descriptor.source.kind, identifier: descriptor.source.identifier)
        guard let check = restoredChecks[source] else { return nil }
        // The source changed since the Restore check began: its context does not guard another version. Revisions
        // have no order, so an older queued version also backs up as an ordinary upload.
        if descriptor.backupRevision != check.context.revision, !check.isCurrent() { return nil }
        guard descriptor.backupRevision == check.context.revision, check.isCurrent() else { throw CancellationError() }
        return check
    }

    private func validateRestoredCheck(_ captured: RestoredCheck?, for descriptor: UploadResourceDescriptor) throws {
        let current = try restoredCheck(for: descriptor)
        guard captured?.context == current?.context else { throw CancellationError() }
        guard captured?.isCurrent() != false else { throw CancellationError() }
    }

    public func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        try await checker.findRemoteAssetProofs(for: identities)
    }

    public func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await checker.prepareRemoteIndex(progress: progress)
    }

    public func remoteIndexPreparationNotNeeded() async {
        await checker.remoteIndexPreparationNotNeeded()
    }

    public func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        try await checker.remoteContentIndexHealth()
    }

    public func identityRecord(for source: UploadSourceIdentity) -> UploadIdentityRecord? {
        store.record(for: source)
    }

    public func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try Task.checkCancellation()
        let restoring = try restoredCheck(for: descriptor)
        if let primingCancellation, primingCancellation.sources.contains(descriptor.source) {
            throw primingCancellation.error
        }
        let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
        let epoch = try await checker.hashKeyEpoch()
        try Task.checkCancellation()
        let cached = store.record(for: descriptor.source)
        let hmacReusable =
            cached.map { $0.isValid(for: descriptor, hashKeyEpoch: epoch) && $0.correctedName == corrected } ?? false
        let preservesKnownDeletion =
            hmacReusable
            && cached?.outcome == UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        // Burst-member rule, see `UploadDuplicateDecisionPolicy.burstMemberCandidates`: the same bytes as an active
        // photo prove nothing. Only this member's own upload, or the server's related list, proves the relation.
        let isBurstMember = descriptor.source.resource.isBurstMember
        // A secondary of a main photo counts only a copy under that main photo. Another main file with the same name
        // or bytes proves nothing. For a secondary of an edit that replaces an earlier upload this also holds: its
        // earlier copy is a related photo of the replaced photo and moves to the trash with it.
        let requiresRelatedMatch = descriptor.needsRelatedProof
        // A main photo of its own. It never adopts a related file of another photo, see `rootEligible`.
        let isRoot = descriptor.source.resource == .primary && descriptor.mainRemoteLinkID == nil

        // Manifest fast path: this exact resource (same name/size/mtime/key epoch) is known to be
        // on the server - uploaded by us or confirmed as an active duplicate. No hash, no query.
        // Known gap: the root check (`rootEligible`) does not run here. A primary row that adopted a related file
        // before that check existed still skips. A local check needs the sources that uploaded a link, and
        // `sources(withRemoteLinkID:)` scans the manifest without an index; once per hit that is quadratic in the
        // library size. Close the gap when the manifest has an indexed reverse lookup by remote link.
        // A frame of a replacing series edit skips it too: its row can name its copy under the replaced main photo.
        // A secondary whose earlier row adopted a copy outside its main photo keeps that row on purpose: earlier marks
        // are not checked again.
        if let cached, hmacReusable, !descriptor.requiresRelatedMatch,
            let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
            outcome == .uploaded || (outcome == .duplicateActive && !isBurstMember),
            let remoteLink = cached.remoteLinkID,
            let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex)
        {
            try validateRestoredCheck(restoring, for: descriptor)
            let identity = UploadIdentity(
                correctedName: cached.correctedName, nameHash: cached.nameHash,
                sha1Hex: cached.sha1Hex, sha1Digest: digest, contentHash: cached.contentHash
            )
            return UploadPreflightResult(
                identity: identity, decision: .skip(.knownFromManifest, remoteLinkID: remoteLink))
        }

        // Content identity - reuse the persisted SHA-1 only while name/size/mtime are unchanged;
        // when unsure, rehash (streamed, cancellable).
        let sha1Digest: Data
        if let cached, cached.isValid(for: descriptor),
            let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex)
        {
            sha1Digest = digest
        } else if let digest = descriptor.precomputedSHA1Digest {
            guard digest.count == 20 else {
                throw UploadError.backend("Invalid precomputed SHA-1 digest")
            }
            sha1Digest = digest
        } else {
            let hasher = self.hasher
            sha1Digest = try await resourceCoordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .backupHashing,
                    intent: descriptor.workIntent,
                    memoryClass: .medium
                )
            ) { _ in
                try await hasher.sha1(of: descriptor)  // streamed and cancellable
            }
        }
        let sha1Hex = UploadContentSHA1.hexString(digest: sha1Digest)

        // Proton-keyed hashes - reused only when the key epoch also matches.
        let nameHash: String
        let contentHash: String
        if let cached, hmacReusable, cached.sha1Hex == sha1Hex {
            nameHash = cached.nameHash
            contentHash = cached.contentHash
        } else {
            nameHash = try await checker.nameHash(forCorrectedName: corrected)  // local HMAC
            contentHash = try await checker.contentHash(forSHA1Hex: sha1Hex)  // local HMAC
        }
        let identity = UploadIdentity(
            correctedName: corrected, nameHash: nameHash,
            sha1Hex: sha1Hex, sha1Digest: sha1Digest, contentHash: contentHash
        )
        try Task.checkCancellation()
        let replacement = try await replacementScope(
            for: descriptor, cached: cached, sha1Hex: sha1Hex, nameHash: nameHash, contentHash: contentHash)
        try Task.checkCancellation()
        func result(_ decision: UploadDuplicateDecision) throws -> UploadPreflightResult {
            do { try validateRestoredCheck(restoring, for: descriptor) } catch {
                releasePendingUploadClaims(ownedBy: descriptor)
                throw error
            }
            return UploadPreflightResult(
                identity: identity, decision: decision,
                lineage: decision.uploadsBytes ? lineage(of: replacement, for: descriptor) : nil)
        }

        // Persist the identity before the remote check so a crash never re-pays the hashing.
        // An outcome from a still-valid prior row survives; anything stale is dropped.
        var record = UploadIdentityRecord(
            source: descriptor.source,
            filename: descriptor.filename,
            correctedName: corrected,
            fileSize: descriptor.fileSize,
            modificationDate: descriptor.modificationDate,
            sha1Hex: sha1Hex,
            nameHash: nameHash,
            contentHash: contentHash,
            hashKeyEpoch: epoch,
            remoteVolumeID: hmacReusable ? cached?.remoteVolumeID : nil,
            remoteLinkID: hmacReusable ? cached?.remoteLinkID : nil,
            outcome: hmacReusable ? cached?.outcome : nil,
            updatedAt: now()
        )
        try validateRestoredCheck(restoring, for: descriptor)
        try persistRecord(record, readFrom: cached)

        // What the server said about the copies under the main photo, read at most once in this resolve.
        var relatedReads = RelatedProofReads()
        // Account-wide content dedupe + same-run coalescing. Loop invariant on exit: either we
        // returned a known-content skip, or we hold the pending-upload claim for this content.
        let contentKey = Self.contentKey(epoch: epoch, contentHash: contentHash)
        while true {
            // Bytes already proven on the server under ANY source path/filename (copied folder,
            // renamed file): adopt that remote link after checking for explicit matching trash, without uploading.
            // A main photo adopts only the link of another main photo, never a burst frame or a paired video.
            // Recheck a known deletion before another source's active row can replace its Restore link.
            if !preservesKnownDeletion, !isBurstMember, !requiresRelatedMatch,
                let known = try await trustedMatch(
                    contentHash: contentHash, epoch: epoch, sha1Hex: sha1Hex, isRoot: isRoot,
                    descriptor: descriptor, replacement: replacement, reads: &relatedReads),
                let knownLink = known.remoteLinkID
            {
                let allowsAdoption: Bool
                do {
                    let rows = try await duplicates(forNameHash: nameHash)
                    try Task.checkCancellation()
                    allowsAdoption = !rows.contains {
                        $0.nameHash == nameHash && $0.contentHash == contentHash && $0.linkState == .trashed
                    }
                } catch {
                    try Task.checkCancellation()
                    if UploadError.isCancellation(error) { throw error }
                    PhotoDiagnostics.shared.increment("upload.cachedAdoptionNameUnavailable")
                    allowsAdoption = true
                }
                if allowsAdoption {
                    try validateRestoredCheck(restoring, for: descriptor)
                    record.remoteVolumeID = known.remoteVolumeID
                    record.remoteLinkID = knownLink
                    record.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
                    record.updatedAt = now()
                    try persistRecord(record)
                    return try result(.skip(.knownFromManifest, remoteLinkID: knownLink))
                }
            }
            guard pendingContentUploads[contentKey] != nil else {
                // Claim the content before the remote check - identical items resolving
                // concurrently must serialize here, not race to independent `.upload` decisions.
                pendingContentUploads[contentKey] = PendingUpload(owner: record, waiters: [:])
                break
            }
            // Identical bytes are uploading right now - wait until that attempt settles
            // (recordUploaded or uploadDidFail), then re-check the manifest.
            try await waitForPendingClaim(contentKey, kind: .content)
            // The check after the wait reads the states again.
            relatedReads = RelatedProofReads()
        }

        // Filename reuse is valid (for example after resetting an iPhone), but Proton drafts are
        // name-scoped. Serialize same-name uploads only for the lifetime of the actual attempt so
        // an own draft observed below cannot belong to another live upload in this process.
        let nameKey = Self.nameKey(epoch: epoch, nameHash: nameHash)
        do {
            try await acquirePendingNameClaim(nameKey, owner: record)
        } catch {
            releasePendingContentClaim(contentKey, owner: descriptor)
            throw error
        }
        // The name claim can wait for another upload of this name; the states read before it are read again.
        relatedReads = RelatedProofReads()

        let remoteItems: [RemotePhotoDuplicate]
        do {
            // A retained trash fact needs fresh evidence, not a name row cached by an earlier run.
            remoteItems =
                preservesKnownDeletion
                ? try await checker.findDuplicates(nameHashes: [nameHash])
                : try await duplicates(forNameHash: nameHash)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || UploadError.isCancellation(error) {
                releasePendingUploadClaims(ownedBy: descriptor)
                try Task.checkCancellation()
                throw error
            }
            let detailedLookupError = error
            // The detailed endpoint is normally faster because `prime` batches large libraries.
            // The SDK gives us an exact fallback: a positive match names a candidate copy, which
            // `countsAsBackup` must still prove below; an empty/failed result cannot authorize
            // an upload, so fail closed with the original detailed-lookup error.
            var exactMatches: [PhotoUID] = []
            do {
                if !isBurstMember && !requiresRelatedMatch && replacement.isEmpty {
                    exactMatches = try await checker.findExactActiveDuplicates(
                        correctedName: corrected, sha1Digest: sha1Digest)
                }
                try Task.checkCancellation()
            } catch {
                releasePendingUploadClaims(ownedBy: descriptor)
                try Task.checkCancellation()
                if UploadError.isCancellation(error) { throw error }
                throw detailedLookupError
            }
            if !exactMatches.isEmpty {
                do {
                    var fallbackReads = RelatedProofReads()
                    if isRoot {
                        let related = try await relatedLinks(
                            among: Set(exactMatches.map(\.nodeID)), requiresActiveMain: false, reads: &fallbackReads)
                        exactMatches.removeAll { related.contains($0.nodeID) }
                    }
                    // An exact match adopts the same proof as a name row: a state read of this check must
                    // prove the copy, see `countsAsBackup`. For a root, an answer without role data never proves
                    // the backup (#876). A non-root accepts any active match, because its legitimate copy is
                    // a related file (documented in `countsAsBackup`).
                    for exact in exactMatches {
                        try await readPrimedState(exact.nodeID, reads: &fallbackReads)
                    }
                    exactMatches.removeAll { !countsAsBackup($0.nodeID, isRoot: isRoot, reads: fallbackReads) }
                } catch {
                    releasePendingUploadClaims(ownedBy: descriptor)
                    throw error
                }
            }
            if let exact = exactMatches.first {
                let decision = UploadDuplicateDecision.skip(.activeDuplicate, remoteLinkID: exact.nodeID)
                do {
                    try Task.checkCancellation()
                    try validateRestoredCheck(restoring, for: descriptor)
                    try persist(decision, in: &record, readFrom: cached)
                } catch {
                    releasePendingUploadClaims(ownedBy: descriptor)
                    throw error
                }
                releasePendingUploadClaims(ownedBy: descriptor)
                return try result(decision)
            }
            releasePendingUploadClaims(ownedBy: descriptor)
            throw detailedLookupError
        }

        let nameCandidates: (items: [RemotePhotoDuplicate], provesLive: Bool)
        do {
            nameCandidates = try await candidates(
                remoteItems, contentHash: contentHash, descriptor: descriptor, replacement: replacement,
                relatedReads: &relatedReads)
            try Task.checkCancellation()
        } catch {
            releasePendingUploadClaims(ownedBy: descriptor)
            throw error
        }
        let nameDecision: UploadDuplicateDecision
        do {
            nameDecision = try await verifiedNameDecision(
                nameCandidates.items,
                primary: .init(source: descriptor.source, nameHash: nameHash, contentHash: contentHash),
                isRoot: isRoot, reads: &relatedReads)
        } catch {
            releasePendingUploadClaims(ownedBy: descriptor)
            throw error
        }

        // Finish both passes before asking about deletion: same bytes outside the scope can prove a deletion,
        // and an active copy under another name can prove the photo live.
        var decision = nameDecision
        var provesLive = nameCandidates.provesLive
        let blockedByDraft: Bool
        if case .skip(.draftExists, _) = nameDecision {
            blockedByDraft = true
        } else {
            blockedByDraft = false
        }
        do {
            // A name draft can hide an active copy under another name. Only active content may
            // settle that block; a miss or an inactive copy leaves the draft protected.
            if nameDecision.uploadsBytes || (blockedByDraft && isRoot && !isBurstMember && !requiresRelatedMatch) {
                do {
                    let limit = isRoot && replacement.isEmpty ? Self.rootMatchBound : 1
                    let found = try await checker.findDuplicates(contentHash: contentHash, limit: limit)
                    for start in stride(from: 0, to: found.count, by: Self.rootMatchBatchSize) {
                        let batch = Array(found[start..<min(start + Self.rootMatchBatchSize, found.count)])
                        let contentCandidates = try await candidates(
                            batch, contentHash: contentHash, descriptor: descriptor, replacement: replacement,
                            requiresActiveMain: blockedByDraft, relatedReads: &relatedReads)
                        provesLive = provesLive || contentCandidates.provesLive
                        let excluded =
                            blockedByDraft
                            ? try await relatedLinks(
                                among: Set(contentCandidates.items.compactMap(\.linkID)), requiresActiveMain: true,
                                reads: &relatedReads)
                            : []
                        var adopted: RemotePhotoDuplicate?
                        for item in contentCandidates.items {
                            if blockedByDraft {
                                guard item.linkState == .active, item.contentHash == contentHash,
                                    let linkID = item.linkID, !linkID.isEmpty, !excluded.contains(linkID)
                                else { continue }
                            }
                            // An index row can outlive its photo for a short time, so an active row counts only when
                            // a state read of this check says that the copy is active.
                            if item.linkState == .active, let linkID = item.linkID, !linkID.isEmpty {
                                try await readInThisCheck([linkID], reads: &relatedReads)
                                guard
                                    countsAsBackup(linkID, isRoot: isRoot, reads: relatedReads)
                                else { continue }
                            }
                            adopted = item
                            break
                        }
                        if let remoteContent = adopted {
                            decision = decisionForRemoteContent(
                                remoteContent,
                                replacingNameHash: nameDecision == .uploadReplacingDraft ? nameHash : nil)
                            break
                        }
                    }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard blockedByDraft else { throw error }
                    if UploadError.isCancellation(error) { throw error }
                    // Transient network and retryable service failures follow the normal check's retry without an
                    // attempt. Other failures leave the draft protected (#877).
                    if case UploadError.retryableBackend = error { throw error }
                    if BackupSyncRunner.isTransientNetwork(error) { throw error }
                    try Task.checkCancellation()
                    decision = nameDecision
                }
            }
            if let link = relatedReads.restoredMemberLinkID, relatedReads.restoredMemberIsUnderDestination {
                decision = .skip(.activeDuplicate, remoteLinkID: link)
            }
            // A vanished trash entry does not revoke the person's deletion: the trash was emptied, or the copy left
            // it otherwise. The photo stays deleted in Proton and never uploads; the record keeps the trash fact, so
            // every later check reads the server again, and an active copy found there still counts (#984).
            if decision.uploadsBytes, preservesKnownDeletion, relatedReads.restoredMemberLinkID == nil {
                decision = .skip(.deletedRemotely, remoteLinkID: cached?.remoteLinkID)
            }
            if decision.uploadsBytes, !replacement.isEmpty, !provesLive,
                descriptor.source.kind == .photoLibraryAsset, descriptor.source.resource == .primary,
                descriptor.mainRemoteLinkID == nil, let replacementJournal
            {
                let entry = replacementJournal.entry(for: descriptor.source)
                if entry.keptDeleted == true {
                    decision = .skip(.deletedRemotely, remoteLinkID: replacement.current)
                } else if entry.backUpAgainRevision
                    != (descriptor.backupRevision ?? UploadBackupRevision(date: descriptor.modificationDate))
                {
                    // The person's consent covers exactly the version they saw; a later edit of a deleted photo
                    // asks again, so a consent that outlived its backup can never upload a later deletion.
                    decision = .awaitDeletionCheck
                }
            }
            try Task.checkCancellation()
            try validateRestoredCheck(restoring, for: descriptor)
            try noteRestored(decision, in: replacement, of: descriptor.source)
            if decision != .awaitDeletionCheck {
                try replacementJournal?.clearDeletionCheck(for: descriptor.source)
            }
            try persist(decision, in: &record, readFrom: cached)
        } catch {
            releasePendingUploadClaims(ownedBy: descriptor)
            throw error
        }
        if !decision.uploadsBytes { releasePendingUploadClaims(ownedBy: descriptor) }
        return try result(decision)
    }

    /// Complete lineage reads can discover a live main without a local manifest. Failed or incomplete reads leave
    /// the existing replacement behavior unchanged. Unedited assets and assets without an iCloud ID use no new read.
    private func replacementScope(
        for descriptor: UploadResourceDescriptor,
        cached: UploadIdentityRecord?,
        sha1Hex: String, nameHash: String, contentHash: String
    ) async throws -> UploadReplacementScope {
        var scope = try localReplacementScope(for: descriptor, cached: cached, sha1Hex: sha1Hex)
        guard let replacementJournal, descriptor.source.kind == .photoLibraryAsset,
            descriptor.source.resource == .primary, descriptor.mainRemoteLinkID == nil,
            let identifier = descriptor.externalIdentifier, !identifier.isEmpty
        else { return scope }
        // Runs on every pass, also on a retry whose remote target the journal already holds.
        scope = try await excludingForeignTargets(
            from: scope, identifier: identifier, isUnique: descriptor.externalIdentifierIsUnique,
            source: descriptor.source, journal: replacementJournal)
        guard descriptor.isEditedPhoto, descriptor.externalIdentifierIsUnique,
            let creationDate = descriptor.photoLibraryCreationDate
        else { return scope }

        // Build every optional fact before changing the local scope or journal.
        let head: String
        let ancestors: Set<String>
        let foreign: Set<String>
        let candidateVisibility: [String: RemoteLinkVisibility]
        let replacesHead: Bool
        do {
            let identity = try await checker.activeMainLinkIDs(forExternalIdentifier: identifier)
            guard identity.complete, identity.links.count == 1, let target = identity.links.first,
                !scope.superseded.contains(target), target != scope.current
            else { return scope }
            let successors = try await checker.replacingMainLinkIDs(ofReplacedLink: scope.current ?? target)
            guard successors.complete, successors.links.subtracting([target]).isEmpty,
                let compound = try await checker.compound(ofMainLink: target),
                compound.externalIdentifier == identifier,
                UploadRemoteReplacementSafety.isSameCaptureSecond(remote: compound.captureDate, local: creationDate)
            else { return scope }
            replacesHead = UploadRemoteReplacementSafety.isNewerVersion(
                localDate: descriptor.photoLibraryEditTime, remoteDate: compound.modificationDate)
            var originals: Set<String> = []
            for sha1 in descriptor.originalSHA1Hex {
                originals.insert(try await checker.contentHash(forSHA1Hex: sha1))
            }
            guard UploadRemoteReplacementSafety.hasAnchor(compound, originalHashes: originals) else { return scope }
            let ancestry = try await checker.replacedLinkIDs(ofReplacingMain: target)
            guard ancestry.complete else { return scope }
            var candidates = try await duplicates(forNameHash: nameHash)
            if let content = try await checker.findDuplicate(contentHash: contentHash) { candidates.append(content) }
            let matches = Set(
                candidates.filter { $0.linkState == .active && $0.contentHash == contentHash }
                    .compactMap(\.linkID))
            let asked = scope.retired.union(scope.superseded).union(scope.gone).union(ancestry.links).union(matches)
                .union([target])
            var knownForeign: Set<String> = []
            for linkID in asked.sorted() {
                let external = try await checker.externalIdentifier(ofMainLink: linkID)
                guard external.complete else { return scope }
                if let remoteIdentifier = external.identifier, remoteIdentifier != identifier {
                    knownForeign.insert(linkID)
                }
            }
            guard !knownForeign.contains(target) else { return scope }
            candidateVisibility = try await checker.linkVisibility(of: asked.sorted())
            try Task.checkCancellation()
            head = target
            ancestors = ancestry.links.subtracting(knownForeign)
            foreign = knownForeign
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if UploadError.isCancellation(error) { throw error }
            try Task.checkCancellation()
            return scope
        }
        guard replacesHead else {
            // A version of this photo that is not older than this edit, for example another device's later edit. It
            // proves the photo live, so nothing asks about a deletion, but it is no target: both versions stay.
            scope.keptHeads = [head]
            return scope
        }
        scope.retired.subtract(foreign)
        scope.gone.subtract(foreign)
        if let current = scope.current, foreign.contains(current) { scope.current = nil }
        try replacementJournal.addRemoteSuperseded(PhotoUID(volumeID: "", nodeID: head), for: descriptor.source)
        // The next edit finds its own upload instead of this head, so the journal keeps what the head replaced.
        try replacementJournal.addProven(head, inherited: ancestors.sorted(), for: descriptor.source)
        let remoteAncestors = ancestors.subtracting(scope.retired).subtracting(scope.superseded)
        scope.superseded.insert(head)
        scope.retired.formUnion(ancestors.subtracting(scope.superseded))
        scope.knownForeignLinks.formUnion(foreign)
        scope.liveHeads = [head]
        scope.candidateVisibility = candidateVisibility
        scope.remoteAncestors = remoteAncestors
        return scope
    }

    /// A locally adopted duplicate can belong to another asset: a known different iCloud identifier proves that, so
    /// such a photo never becomes a replacement target. Failed or incomplete reads keep the scope unchanged.
    /// The same identifier of a unique asset proves the link for the lineage marker. Without that proof the marker
    /// leaves the link out, which is the safe side: another device then keeps the trashed photo as a deletion.
    private func excludingForeignTargets(
        from scope: UploadReplacementScope, identifier: String, isUnique: Bool, source: UploadSourceIdentity,
        journal: any EditReplacementJournaling
    ) async throws -> UploadReplacementScope {
        guard !scope.superseded.isEmpty else { return scope }
        var foreign: Set<String> = []
        var proven: [String] = []
        do {
            for linkID in scope.superseded.sorted() {
                let external = try await checker.externalIdentifier(ofMainLink: linkID)
                guard external.complete else { return scope }
                guard let remote = external.identifier else { continue }
                if remote != identifier {
                    foreign.insert(linkID)
                } else if isUnique {
                    proven.append(linkID)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if UploadError.isCancellation(error) { throw error }
            try Task.checkCancellation()
            return scope
        }
        try Task.checkCancellation()
        // An adopted head never reaches the discovery below, so the journal keeps what its marker named here.
        var inherited: [String: [String]] = [:]
        for linkID in proven { inherited[linkID] = try await inheritedLinks(of: linkID, identifier: identifier) }
        try Task.checkCancellation()
        for linkID in proven { try journal.addProven(linkID, inherited: inherited[linkID] ?? [], for: source) }
        guard !foreign.isEmpty else { return scope }
        try journal.settle(foreign, related: [], trashed: false, for: source)
        var scope = scope
        scope.superseded.subtract(foreign)
        scope.retired.subtract(foreign)
        if let current = scope.current, foreign.contains(current) { scope.current = nil }
        scope.knownForeignLinks.formUnion(foreign)
        return scope
    }

    /// What the marker of a proven link named, without links of other photos. Empty after a failed or incomplete
    /// read, so the journal never keeps a partial list.
    private func inheritedLinks(of linkID: String, identifier: String) async throws -> [String] {
        do {
            let ancestry = try await checker.replacedLinkIDs(ofReplacingMain: linkID)
            guard ancestry.complete else { return [] }
            var inherited: [String] = []
            for ancestor in ancestry.links.sorted() {
                let external = try await checker.externalIdentifier(ofMainLink: ancestor)
                guard external.complete else { return [] }
                if external.identifier.map({ $0 == identifier }) ?? true { inherited.append(ancestor) }
            }
            return inherited
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if UploadError.isCancellation(error) { throw error }
            try Task.checkCancellation()
            return []
        }
    }

    /// A photo-library primary with other bytes than its proven earlier upload was edited. The journal keeps the
    /// earlier photo before the record below forgets it, so the backup can replace it after the upload.
    private func localReplacementScope(
        for descriptor: UploadResourceDescriptor,
        cached: UploadIdentityRecord?,
        sha1Hex: String
    ) throws -> UploadReplacementScope {
        guard let replacementJournal, descriptor.source.kind == .photoLibraryAsset,
            descriptor.source.resource == .primary, descriptor.mainRemoteLinkID == nil
        else {
            return UploadReplacementScope(superseded: [], retired: [], current: nil)
        }
        var entry = replacementJournal.entry(for: descriptor.source)
        // The manifest names the last upload of this photo, also when its bytes did not change.
        var lastUpload: String?
        if let cached, cached.provesUpload,
            let link = cached.remoteLinkID, !link.isEmpty
        {
            lastUpload = link
            if cached.sha1Hex != sha1Hex, !entry.superseded.contains(where: { $0.nodeID == link }) {
                let uid = PhotoUID(volumeID: cached.remoteVolumeID ?? "", nodeID: link)
                try replacementJournal.addSuperseded(uid, for: descriptor.source)
                entry.superseded.append(uid)
            }
            // Only an own upload proves itself. An adopted duplicate needs its iCloud identifier.
            if cached.sha1Hex != sha1Hex, cached.outcome == UploadIdentityManifestStore.Outcome.uploaded.rawValue {
                try replacementJournal.addProven(link, inherited: [], for: descriptor.source)
            }
        }
        return UploadReplacementScope(
            superseded: Set(entry.superseded.map(\.nodeID)), retired: Set(entry.retired),
            current: lastUpload ?? entry.superseded.last?.nodeID, gone: Set(entry.gone ?? []))
    }

    /// What a replacing upload names: the proven earlier uploads of the journal, newest first. Links of other photos
    /// never appear. The backup attaches it only when its replacement policy replaces earlier uploads.
    private func lineage(
        of scope: UploadReplacementScope, for descriptor: UploadResourceDescriptor
    )
        -> UploadLineageMarker?
    {
        guard !scope.isEmpty, descriptor.source.resource == .primary, let replacementJournal else { return nil }
        let entry = replacementJournal.entry(for: descriptor.source)
        return UploadLineageMarker(
            reason: descriptor.isEditedPhoto ? .edit : .undo,
            history: entry.replacementHistory(excluding: scope.knownForeignLinks))
    }

    /// The remote rows that can prove this resource. A burst member and a secondary of a main photo count
    /// only a copy under their main photo as saved. A primary ignores the photos that an edit replaces or replaced and
    /// their related photos: the backup moves those to the trash itself, so they are neither this photo nor a
    /// deletion by the person.
    private func candidates(
        _ remoteItems: [RemotePhotoDuplicate],
        contentHash: String,
        descriptor: UploadResourceDescriptor,
        replacement: UploadReplacementScope,
        requiresActiveMain: Bool = false,
        relatedReads: inout RelatedProofReads
    ) async throws -> (items: [RemotePhotoDuplicate], provesLive: Bool) {
        if !relatedReads.restoredMemberChecked {
            relatedReads.restoredMemberChecked = true
            if let check = try restoredCheck(for: descriptor), let destination = descriptor.mainRemoteLinkID,
                let cached = store.record(for: descriptor.source), cached.isValid(for: descriptor),
                cached.outcome == UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue,
                let member = cached.remoteLinkID
            {
                let confirmed = check.context.confirmedRemote.nodeID
                let visibility = try await checker.linkVisibility(
                    of: Array(Set([confirmed, destination, member])).sorted())
                try Task.checkCancellation()
                guard check.isCurrent(), restoredChecks[check.context.source]?.context == check.context else {
                    throw CancellationError()
                }
                if let oldMain = visibility[confirmed], oldMain.hasExplicitPhotoState, oldMain.isActiveMain,
                    let newMain = visibility[destination], newMain.hasExplicitPhotoState, newMain.isActiveMain,
                    let file = visibility[member], file.hasExplicitPhotoState, file.isActive,
                    file.mainPhotoLinkID == confirmed || file.mainPhotoLinkID == destination
                {
                    relatedReads.restoredMemberLinkID = member
                    relatedReads.restoredMemberIsUnderDestination = file.mainPhotoLinkID == destination
                }
            }
        }
        // Only the exact retained member with fresh positive proof can replace its earlier trash row.
        let remoteItems = remoteItems.map { item in
            guard item.linkID == relatedReads.restoredMemberLinkID, item.linkID != nil,
                item.contentHash == contentHash, item.linkState == .trashed
            else { return item }
            return RemotePhotoDuplicate(
                nameHash: item.nameHash, contentHash: item.contentHash, linkState: .active,
                linkID: item.linkID, clientUID: item.clientUID)
        }
        if descriptor.source.resource.isBurstMember {
            return (
                try await burstMemberCandidates(remoteItems, contentHash: contentHash, descriptor: descriptor), false
            )
        }
        if descriptor.needsRelatedProof {
            // A secondary of a replacing edit counts only a copy under its main photo. A plain secondary drops active
            // and trashed copies elsewhere: a trashed copy is a deletion by the person only when it belongs to this
            // photo. A row without State stays unknown; a draft keeps its normal protection.
            // Only a row with these bytes can decide the secondary, so only such a row is checked.
            let countsOnlyUnderTheMainPhoto: (RemotePhotoDuplicate) -> Bool = {
                descriptor.requiresRelatedMatch
                    ? $0.linkState != .draft : $0.linkState == .active || $0.linkState == .trashed
            }
            let toProve = Set(
                remoteItems.filter { countsOnlyUnderTheMainPhoto($0) && $0.contentHash == contentHash }
                    .compactMap(\.linkID))
            // A link that a row also lists as active needs a stated role like any active copy.
            let activeToProve = Set(
                remoteItems.filter { $0.linkState == .active && $0.contentHash == contentHash }.compactMap(\.linkID))
            let trashedToProve = toProve.subtracting(activeToProve)
            var relatedLinkIDs: Set<String> = []
            if !toProve.isEmpty, let mainLinkID = descriptor.mainRemoteLinkID {
                if descriptor.requiresRelatedMatch {
                    // The main photo of a replacing edit is the upload that just finished, so its list can be read.
                    if let read = relatedReads.relatedByMain[mainLinkID] {
                        relatedLinkIDs = read
                    } else {
                        relatedLinkIDs = try await checker.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
                        try Task.checkCancellation()
                        relatedReads.relatedByMain[mainLinkID] = relatedLinkIDs
                    }
                } else {
                    // The main photo can be in the trash, and the server refuses its list then. The role of each copy
                    // answers in that case too. Every active copy with these bytes needs an answer that states its
                    // role: a failed read, a copy the answer leaves out, or an answer without the photo state fails
                    // the check, so an unproven own copy never uploads a second time. A trashed copy proves deletion
                    // only when its stated role names this main photo.
                    let unasked = toProve.subtracting(relatedReads.askedLinks)
                    if !unasked.isEmpty {
                        let read = try await checker.linkVisibility(of: unasked.sorted())
                        try Task.checkCancellation()
                        relatedReads.askedLinks.formUnion(unasked)
                        relatedReads.visibility.merge(read) { _, new in new }
                    }
                    let stated = toProve.filter { relatedReads.visibility[$0]?.hasExplicitPhotoState == true }
                    guard toProve.subtracting(stated).isSubset(of: trashedToProve) else {
                        throw UploadError.backend("The role of a copy with these bytes is unavailable")
                    }
                    relatedLinkIDs = stated.filter { relatedReads.visibility[$0]?.mainPhotoLinkID == mainLinkID }
                }
            }
            return (
                remoteItems.filter { item in
                    guard let linkID = item.linkID else {
                        // An active or trashed copy without a link cannot be proven either way. It stays, so a plain
                        // secondary keeps the earlier answer: an inconsistent answer or a deletion by the person.
                        return !descriptor.requiresRelatedMatch || !countsOnlyUnderTheMainPhoto(item)
                    }
                    return !countsOnlyUnderTheMainPhoto(item) || relatedLinkIDs.contains(linkID)
                }, false
            )
        }
        guard !replacement.isEmpty else {
            guard descriptor.source.resource == .primary, descriptor.mainRemoteLinkID == nil else {
                return (remoteItems, false)
            }
            return (
                try await rootEligible(
                    remoteItems, contentHash: contentHash, requiresActiveMain: requiresActiveMain,
                    reads: &relatedReads),
                false
            )
        }
        // Only the state of a photo shows that it is still in the library: its current upload is active, the
        // person restored an earlier version, or an active main photo holds these bytes.
        let matches = remoteItems.filter { $0.linkState == .active && $0.contentHash == contentHash }
            .compactMap(\.linkID)
        var asked = replacement.retired.union(replacement.gone).union(matches).union(replacement.keptHeads)
        if let current = replacement.current { asked.insert(current) }
        let visibility: [String: RemoteLinkVisibility]
        if let optional = replacement.candidateVisibility {
            visibility = optional
        } else {
            visibility = try await checker.linkVisibility(of: asked.sorted())
            relatedReads.askedLinks.formUnion(asked)
            relatedReads.visibility.merge(visibility) { _, new in new }
        }
        try Task.checkCancellation()
        func isLiveMain(_ linkID: String) -> Bool {
            guard visibility[linkID]?.hasExplicitPhotoState == true else { return false }
            return visibility[linkID]?.isActiveMain ?? false
        }
        let ownMatches = Set(matches.filter(isLiveMain)).filter {
            !replacement.knownForeignLinks.contains($0)
        }
        let adoptable = ownMatches.subtracting(replacement.superseded.subtracting(replacement.liveHeads))
        let liveRetired = replacement.retired.filter(isLiveMain)
        let restored = liveRetired.subtracting(adoptable).subtracting(replacement.remoteAncestors)
        // A gone photo that is in the library again proves the photo live, but the person restored it: it never
        // becomes an earlier version that this upload replaces.
        let liveGone = replacement.gone.filter(isLiveMain)
        // A newer version of another device proves the photo live only while it is in the library now.
        let liveKeptHeads = replacement.keptHeads.filter(isLiveMain)

        guard
            replacement.current.map(isLiveMain) == true || !replacement.liveHeads.isEmpty
                || !liveKeptHeads.isEmpty || !restored.isEmpty || !adoptable.isEmpty || !liveGone.isEmpty
        else {
            // Nothing proves the photo live. Who removed it stays unknown, so the earlier rule applies: the
            // photos of the replacement do not count, and a trashed copy outside them is a deletion by the person.
            // An active copy under a main photo is a related file, such as the hidden original under a replaced
            // photo. It is no backup. The states above name those copies without a lookup of the related photos
            // of a main photo that may be in the trash or gone. Missing or inactive visibility does not prove
            // State 2; keep that row unknown instead of manufacturing a deletion that a later run could retain.
            // A gone earlier photo left without a known author, so its trash is no deletion proof either. Only an
            // explicit state makes a copy a related file; a role without a state stays unknown below.
            let related = Set(
                matches.filter {
                    visibility[$0].map { $0.hasExplicitPhotoState && $0.isActive && $0.mainPhotoLinkID != nil }
                        ?? false
                })
            let unknown = Set(
                matches.filter {
                    visibility[$0].map { $0.hasExplicitPhotoState && $0.isActive } != true
                })
            let excluded = replacement.superseded.union(replacement.retired).union(replacement.gone).union(related)
            return (
                remoteItems.compactMap { item in
                    guard let linkID = item.linkID else { return item }
                    guard !excluded.contains(linkID) else { return nil }
                    guard unknown.contains(linkID) else { return item }
                    return RemotePhotoDuplicate(
                        nameHash: item.nameHash, contentHash: item.contentHash, linkState: nil, linkID: linkID,
                        clientUID: item.clientUID)
                }, false
            )
        }
        if replacement.current.map(isLiveMain) == true || !liveRetired.isEmpty || !liveGone.isEmpty
            || !liveKeptHeads.isEmpty
        {
            try replacementJournal?.clearDeletionChoice(for: descriptor.source)
        }
        // A restored earlier version with other bytes is an earlier photo again, so this upload replaces it.
        if !restored.isEmpty {
            try replacementJournal?.unretire(restored, for: descriptor.source)
            for linkID in restored.sorted() {
                let uid = PhotoUID(volumeID: "", nodeID: linkID)
                try replacementJournal?.addSuperseded(uid, for: descriptor.source)
            }
        }
        // The photo is in the library, so a trashed or deleted copy of these bytes is an earlier version that the
        // backup replaced, not a deletion by the person. An active copy counts only as a main photo: the hidden
        // original under the photo that this upload replaces, or a related file of a trashed photo, is no backup.
        let scope = replacement.superseded.union(replacement.retired).union(replacement.gone)
        // Lineage contract: the guard above proves an active holder, and only an inactive named link drops out here.
        return (
            remoteItems.filter { item in
                guard item.linkState != .draft else { return true }
                guard item.linkState == .active, let linkID = item.linkID else { return false }
                return item.contentHash == contentHash ? adoptable.contains(linkID) : !scope.contains(linkID)
            }, true
        )
    }

    /// A main photo with no replacement never adopts a related file of another photo: a burst frame, the original
    /// under an edited photo, or a paired video. Those bytes do not make a photo of their own, so the primary
    /// uploads as its own photo. With a replacement, `candidates` already counts only live main photos.
    private func rootEligible(
        _ remoteItems: [RemotePhotoDuplicate], contentHash: String, requiresActiveMain: Bool,
        reads: inout RelatedProofReads
    ) async throws -> [RemotePhotoDuplicate] {
        let matches = Set(
            remoteItems.filter { $0.linkState == .active && $0.contentHash == contentHash }.compactMap(\.linkID))
        guard !matches.isEmpty else { return remoteItems }
        let related = try await relatedLinks(among: matches, requiresActiveMain: requiresActiveMain, reads: &reads)
        guard !related.isEmpty else { return remoteItems }
        return remoteItems.filter { item in item.linkID.map { !related.contains($0) } ?? true }
    }

    /// The manifest row whose remote link this resource may adopt. For a root, a primary row proves no main photo:
    /// an earlier version stored the related file that a primary adopted. So a root weighs up to `rootMatchBound`
    /// rows and takes the first one whose link the server does not name as a related file. Another device can have
    /// trashed the copy since the row was written, so a row counts only when a state read of this check proves its
    /// copy, see `countsAsBackup`.
    private func trustedMatch(
        contentHash: String, epoch: String, sha1Hex: String, isRoot: Bool,
        descriptor: UploadResourceDescriptor, replacement: UploadReplacementScope, reads: inout RelatedProofReads
    ) async throws -> UploadIdentityRecord? {
        let guardsRoot = isRoot && replacement.isEmpty
        let rows = store.trustedRecords(
            contentHash: contentHash, hashKeyEpoch: epoch, limit: guardsRoot ? Self.rootMatchBound : 1
        ).filter { known in
            known.sha1Hex == sha1Hex && known.remoteLinkID != nil
                && (!isRoot || known.source.resource == .primary)
                && (replacement.isEmpty || known.source == descriptor.source)
        }
        // A failed read adopts nothing; the remote check below decides.
        func read(_ linkIDs: Set<String>) async throws -> Bool {
            do {
                try await readInThisCheck(linkIDs, reads: &reads)
                return true
            } catch {
                if Task.isCancelled || UploadError.isCancellation(error) { throw error }
                return false
            }
        }
        guard guardsRoot else {
            guard let row = rows.first, let linkID = row.remoteLinkID, try await read([linkID]) else { return nil }
            let proves = countsAsBackup(linkID, isRoot: isRoot, reads: reads)
            return proves ? row : nil
        }
        // Several sources can name one related link; it is weighed once.
        var rejected: Set<String> = []
        var remaining = rows[...]
        while !remaining.isEmpty {
            var batch: [UploadIdentityRecord] = []
            var batchLinks: Set<String> = []
            while batchLinks.count < Self.rootMatchBatchSize, let row = remaining.popFirst() {
                guard let linkID = row.remoteLinkID, !rejected.contains(linkID) else { continue }
                batch.append(row)
                batchLinks.insert(linkID)
            }
            guard !batch.isEmpty else { break }
            guard try await read(batchLinks) else { return nil }
            if let eligible = batch.first(where: { row in
                row.remoteLinkID.map { countsAsBackup($0, isRoot: true, reads: reads) } ?? false
            }) {
                return eligible
            }
            rejected.formUnion(batchLinks)
        }
        return nil
    }

    /// The links that the server names as a related file of a main photo. The name and duplicate rows carry no
    /// role, so the visibility read proves it. `prime` normally read it already; only a link that it did not
    /// cover costs one read here. A link that the server no longer names, or a failed read, proves nothing: the
    /// rows stay as listed, as before this check. A blocked name instead requires positive active-main proof:
    /// strict callers also exclude unknown and inactive links.
    private func relatedLinks(
        among linkIDs: Set<String>, requiresActiveMain: Bool = false
    ) async throws -> Set<String> {
        var reads = RelatedProofReads()
        return try await relatedLinks(among: linkIDs, requiresActiveMain: requiresActiveMain, reads: &reads)
    }

    /// Like `relatedLinks(among:requiresActiveMain:)`, and records the states that answered in `reads`.
    private func relatedLinks(
        among linkIDs: Set<String>, requiresActiveMain: Bool, reads: inout RelatedProofReads
    ) async throws -> Set<String> {
        var known = rootVisibility
        // A blocked name needs a positive answer of this check: a copy that an earlier check saw inactive, or that the
        // server did not name, can be back. Such a copy is read again once in this check (#877).
        let staleNegatives =
            requiresActiveMain
            ? linkIDs.filter { linkID in
                rootVisibilityAsked.contains(linkID) && !reads.askedLinks.contains(linkID)
                    && rootVisibility[linkID].map(Self.provesActiveMain) != true
            } : []
        let unasked = linkIDs.subtracting(rootVisibilityAsked).union(staleNegatives)
        if !unasked.isEmpty {
            let generation = cacheGeneration
            var read: [String: RemoteLinkVisibility] = [:]
            do {
                read = try await checker.linkVisibility(of: unasked.sorted())
                try Task.checkCancellation()
                reads.askedLinks.formUnion(unasked)
                reads.visibility.merge(read) { _, new in new }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if UploadError.isCancellation(error) { throw error }
                guard !requiresActiveMain else { throw error }
                try Task.checkCancellation()
            }
            // A view invalidated while this read ran stays invalidated; the answer still serves this resolve.
            if generation == cacheGeneration {
                rootVisibilityAsked.formUnion(unasked)
                rootVisibility.merge(read) { _, new in new }
            }
            known = rootVisibility.merging(read) { _, new in new }
        }
        return linkIDs.filter {
            if requiresActiveMain {
                return known[$0].map(Self.provesActiveMain) != true
            }
            return known[$0]?.mainPhotoLinkID != nil
        }
    }

    /// An earlier version that the person restored is the photo again: it leaves the retired list.
    private func noteRestored(
        _ decision: UploadDuplicateDecision, in replacement: UploadReplacementScope, of source: UploadSourceIdentity
    ) throws {
        guard case .skip(.activeDuplicate, let linkID?) = decision, replacement.retired.contains(linkID) else {
            return
        }
        try replacementJournal?.unretire([linkID], for: source)
    }

    /// Reads the state of each of `linkIDs` once in this check. A copy that an earlier check read, or whose read
    /// failed, is read again. A failed read fails the check.
    private func readInThisCheck(_ linkIDs: Set<String>, reads: inout RelatedProofReads) async throws {
        let unasked = linkIDs.subtracting(reads.askedLinks)
        guard !unasked.isEmpty else { return }
        let read = try await checker.linkVisibility(of: unasked.sorted())
        try Task.checkCancellation()
        reads.askedLinks.formUnion(unasked)
        reads.visibility.merge(read) { _, new in new }
    }

    /// Takes the state of `linkID` for this check from `prime` while that answer is at most `primedStateLifetime`
    /// old. Otherwise reads it again, together with the next primed links whose answers are just as old, at most
    /// `batchSize` links in one request, so a large batch of roots costs about one request for each `batchSize`
    /// roots. A resolve that needs a link of a running refresh waits for it. A failed read fails the check.
    private func readPrimedState(_ linkID: String, reads: inout RelatedProofReads) async throws {
        guard !reads.askedLinks.contains(linkID) else { return }
        guard !isCurrentPrimedState(linkID) else {
            reads.askedLinks.insert(linkID)
            reads.visibility[linkID] = rootVisibility[linkID]
            return
        }
        let read: [String: RemoteLinkVisibility]
        if let running = stateRefreshes[linkID] {
            PhotoDiagnostics.shared.increment("upload.stateRefreshJoined")
            read = try await running.value
        } else {
            var batch = [linkID]
            if let position = rootVisibilityPositions[linkID] {
                for next in rootVisibilityOrder[(position + 1)...] {
                    guard batch.count < batchSize else { break }
                    if !isCurrentPrimedState(next), stateRefreshes[next] == nil { batch.append(next) }
                }
            }
            let checker = checker
            let links = batch
            let refresh = Task { try await checker.linkVisibility(of: links) }
            let generation = cacheGeneration
            for link in batch { stateRefreshes[link] = refresh }
            defer {
                for link in batch where stateRefreshes[link] == refresh { stateRefreshes[link] = nil }
            }
            read = try await refresh.value
            if generation == cacheGeneration {
                let answeredAt = now()
                rootVisibilityAsked.formUnion(batch)
                for link in batch {
                    rootVisibility[link] = read[link]
                    rootVisibilityReadAt[link] = answeredAt
                }
            }
        }
        try Task.checkCancellation()
        reads.askedLinks.insert(linkID)
        reads.visibility[linkID] = read[linkID]
    }

    /// Whether a complete read answered for `linkID` at most `primedStateLifetime` ago.
    private func isCurrentPrimedState(_ linkID: String) -> Bool {
        guard let answeredAt = rootVisibilityReadAt[linkID] else { return false }
        let age = now().timeIntervalSince(answeredAt)
        return age >= 0 && age <= Self.primedStateLifetime
    }

    /// Whether a state answer explicitly proves an active main photo. An answer without the photo role data
    /// never proves a root backup (#876). See `countsAsBackup`.
    private static func provesActiveMain(_ state: RemoteLinkVisibility) -> Bool {
        state.isActiveMain && state.hasExplicitPhotoState
    }

    /// Whether the read of this check proves that `linkID` backs up this resource. The copy must be active; a copy
    /// that the answer leaves out is no active copy. A root photo is backed up only by a main photo, not by another
    /// photo's related file, and only by an answer that explicitly carries the photo state: an answer without role
    /// data never proves a root backup (#876). A non-root, such as a paired video, has no role of its own to carry:
    /// its legitimate copy is another photo's related file, so any active answer proves it.
    private func countsAsBackup(_ linkID: String, isRoot: Bool, reads: RelatedProofReads) -> Bool {
        guard let state = reads.visibility[linkID], state.isActive else { return false }
        guard isRoot else { return true }
        return Self.provesActiveMain(state)
    }

    /// The decision of the name rows. A name row can outlive its copy like an index row: an active duplicate counts
    /// only when a current state proves its copy, see `readPrimedState`. Otherwise a copy in the trash stays a
    /// deletion by the person, a copy in another inactive state becomes unknown, a copy that the answer leaves out or
    /// that is no main photo leaves the rows, and the rows decide again.
    private func verifiedNameDecision(
        _ items: [RemotePhotoDuplicate], primary: UploadDuplicateDecisionPolicy.Resource, isRoot: Bool,
        reads: inout RelatedProofReads
    ) async throws -> UploadDuplicateDecision {
        var items = items
        while true {
            let decision = UploadDuplicateDecisionPolicy.decide(
                primary: primary, remoteItems: items, currentClientUID: currentClientUID)
            guard case .skip(.activeDuplicate, let linkID?) = decision else { return decision }
            try await readPrimedState(linkID, reads: &reads)
            if countsAsBackup(linkID, isRoot: isRoot, reads: reads) {
                return decision
            }
            let state = reads.visibility[linkID]
            items = items.compactMap { item in
                guard item.linkID == linkID else { return item }
                // A copy in the trash stays the person's deletion. Another state that is not active is unknown: the
                // policy then neither uploads nor counts a deletion.
                guard let state, !state.isActive else { return nil }
                return RemotePhotoDuplicate(
                    nameHash: item.nameHash, contentHash: item.contentHash,
                    linkState: state.trashTime == nil ? nil : .trashed, linkID: item.linkID, clientUID: item.clientUID)
            }
        }
    }

    /// What one resolve learned about the copies that could prove a secondary or a matching copy.
    private struct RelatedProofReads {
        var relatedByMain: [String: Set<String>] = [:]
        var visibility: [String: RemoteLinkVisibility] = [:]
        var askedLinks: Set<String> = []
        var restoredMemberChecked = false
        var restoredMemberLinkID: String?
        var restoredMemberIsUnderDestination = false
    }

    /// Applies the burst-member rule. The server names the related photos of the member's main photo only when
    /// an active row with the member's content exists, so a new series costs no extra request.
    private func burstMemberCandidates(
        _ remoteItems: [RemotePhotoDuplicate],
        contentHash: String,
        descriptor: UploadResourceDescriptor
    ) async throws -> [RemotePhotoDuplicate] {
        let hasActiveContentMatch = remoteItems.contains { $0.linkState == .active && $0.contentHash == contentHash }
        var relatedLinkIDs: Set<String> = []
        if hasActiveContentMatch, let mainLinkID = descriptor.mainRemoteLinkID {
            relatedLinkIDs = try await checker.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
        }
        return UploadDuplicateDecisionPolicy.burstMemberCandidates(
            remoteItems, contentHash: contentHash, relatedLinkIDs: relatedLinkIDs)
    }

    /// Validates a manifest-proven resource after a secondary failure. Permanent deletion needs complete metadata
    /// absence and an independent complete all-state duplicate miss. Unknown evidence never authorizes an upload.
    public func revalidateKnownRemote(
        _ descriptor: UploadResourceDescriptor
    ) async throws -> UploadDuplicateDecision? {
        let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
        let epoch = try await checker.hashKeyEpoch()
        try Task.checkCancellation()
        guard let cached = store.record(for: descriptor.source),
            cached.isValid(for: descriptor, hashKeyEpoch: epoch),
            cached.correctedName == corrected,
            let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
            outcome == .uploaded || outcome == .duplicateActive,
            let knownLinkID = cached.remoteLinkID
        else {
            return nil
        }

        // This path exists specifically because a cached manifest answer is no longer sufficient.
        // Bypass both pipeline and backend caches so a recent trash/delete event is observable.
        invalidateNameCache()
        await checker.invalidateCachedRemoteState()
        try Task.checkCancellation()

        // Revalidation is intentionally one asset at a time, so the SDK exact lookup handles the
        // common still-active case without adding round trips to batched initial scans.
        if let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex) {
            let exactMatches = try await checker.findExactActiveDuplicates(
                correctedName: corrected,
                sha1Digest: digest
            )
            try Task.checkCancellation()
            if let active = exactMatches.first {
                // The exact SDK row carries no role data. A state read of this check must prove an
                // active main photo (#876) before this read-only path may skip. An unproven match is
                // not adopted; revalidation falls through to the name-row and content evidence.
                var fallbackReads = RelatedProofReads()
                try await readPrimedState(active.nodeID, reads: &fallbackReads)
                if countsAsBackup(active.nodeID, isRoot: true, reads: fallbackReads) {
                    return .skip(.activeDuplicate, remoteLinkID: active.nodeID)
                }
            }
        }

        // An SDK miss does not say whether the known item was trashed or deleted. Preserve the
        // detailed Photos response and content index for that distinction.
        let remoteItems = try await checker.findDuplicates(nameHashes: [cached.nameHash])
        try Task.checkCancellation()
        let nameDecision = UploadDuplicateDecisionPolicy.decide(
            primary: .init(
                source: descriptor.source,
                nameHash: cached.nameHash,
                contentHash: cached.contentHash
            ),
            remoteItems: remoteItems,
            // Revalidation may only prove that a previously-known primary was deleted. It must
            // never authorize replacement of a draft from this read-only path.
            currentClientUID: nil
        )
        guard nameDecision.uploadsBytes else { return nameDecision }

        let remoteContent = try await checker.findDuplicate(contentHash: cached.contentHash)
        try Task.checkCancellation()
        if let remoteContent { return decisionForRemoteContent(remoteContent, replacingNameHash: nil) }
        let states = try await UploadRemoteDeletionLookup.states(
            for: [knownLinkID], checker: checker)
        try Task.checkCancellation()
        switch states[knownLinkID] {
        case .trashed: return .skip(.trashedDuplicate, remoteLinkID: knownLinkID)
        case nil: return nil
        }
    }

    /// Persists only outcomes that remain useful across runs. Active duplicates are trusted by the
    /// manifest fast path. Trashed rows are diagnostic only and are rechecked because users can
    /// restore or permanently delete them. Draft/deleted states stay transient.
    private func persist(
        _ decision: UploadDuplicateDecision, in record: inout UploadIdentityRecord,
        readFrom cached: UploadIdentityRecord?
    ) throws {
        switch decision {
        case .skip(.activeDuplicate, let remoteLinkID):
            record.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
            record.remoteLinkID = remoteLinkID
            record.updatedAt = now()
            try persistRecord(record, readFrom: cached)
        case .skip(.trashedDuplicate, let remoteLinkID):
            record.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
            record.remoteLinkID = remoteLinkID
            record.updatedAt = now()
            try persistRecord(record, readFrom: cached)
        case .upload, .uploadReplacingDraft, .awaitDeletionCheck, .uploadMissingSecondaries, .skip:
            break
        }
    }

    /// A record that still names the remote link of `cached`, the row that this resolve read, keeps the link and
    /// outcome that the store holds when they changed since that read: a merge of exact duplicates can move the row to
    /// the kept photo while this resolve runs, and the link that it read can be in the trash.
    private func persistRecord(_ record: UploadIdentityRecord, readFrom cached: UploadIdentityRecord? = nil) throws {
        let carriesReadLink = cached.map { record.remoteLinkID == $0.remoteLinkID } ?? false
        let written =
            carriesReadLink
            ? store.upsert(record, keepingRemoteLinkChangedFrom: cached?.remoteLinkID) : store.upsert(record)
        guard written else {
            throw UploadError.backend("Upload identity manifest could not be updated")
        }
    }

    private func decisionForRemoteContent(
        _ remote: RemotePhotoDuplicate,
        replacingNameHash: String?
    ) -> UploadDuplicateDecision {
        switch remote.linkState {
        case .draft:
            if let currentClientUID,
                remote.clientUID == currentClientUID,
                remote.nameHash == replacingNameHash
            {
                return .uploadReplacingDraft
            }
            return .skip(.draftExists, remoteLinkID: remote.linkID)
        case .trashed:
            return .skip(.trashedDuplicate, remoteLinkID: remote.linkID)
        case nil:
            return .skip(.inconsistentRemoteState, remoteLinkID: remote.linkID)
        case .active:
            guard let linkID = remote.linkID, !linkID.isEmpty else {
                return .skip(.inconsistentRemoteState, remoteLinkID: nil)
            }
            return .skip(.activeDuplicate, remoteLinkID: linkID)
        }
    }

    /// Releases the same-content claim (if `owner` still holds it) and wakes every waiter so it
    /// re-checks the manifest / re-resolves against fresh state.
    private func releasePendingContentClaim(_ key: String, owner: UploadResourceDescriptor) {
        guard let pending = pendingContentUploads[key], pending.owner.isValid(for: owner) else { return }
        pendingContentUploads[key] = nil
        for waiter in pending.waiters.values { waiter.resume() }
    }

    private func acquirePendingNameClaim(
        _ key: String,
        owner: UploadIdentityRecord
    ) async throws {
        while true {
            guard pendingNameUploads[key] != nil else {
                pendingNameUploads[key] = PendingUpload(owner: owner, waiters: [:])
                return
            }
            try await waitForPendingClaim(key, kind: .name)
        }
    }

    private enum ClaimKind: Sendable { case content, name }

    private func waitForPendingClaim(_ key: String, kind: ClaimKind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                switch kind {
                case .content:
                    if pendingContentUploads[key] != nil {
                        pendingContentUploads[key]!.waiters[id] = continuation
                    } else {
                        continuation.resume()
                    }
                case .name:
                    if pendingNameUploads[key] != nil {
                        pendingNameUploads[key]!.waiters[id] = continuation
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelClaimWaiter(key, kind: kind, id: id) }
        }
        try Task.checkCancellation()
    }

    private func cancelClaimWaiter(_ key: String, kind: ClaimKind, id: UUID) {
        let continuation: CheckedContinuation<Void, any Error>?
        switch kind {
        case .content: continuation = pendingContentUploads[key]?.waiters.removeValue(forKey: id)
        case .name: continuation = pendingNameUploads[key]?.waiters.removeValue(forKey: id)
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// Drops the cached remote view (and detaches in-flight lookups) so the next `resolve`
    /// re-queries the server. Called after failed/cancelled upload attempts and before
    /// draft-blocked re-checks - the moments where the server may know more than the cache.
    public func invalidateCachedRemoteState() async {
        invalidateNameCache()
        await checker.invalidateCachedRemoteState()
    }

    public func remoteMainsChangedHere() async {
        invalidateNameCache()
        await checker.remoteMainsChangedHere()
    }

    private func invalidateNameCache() {
        cacheGeneration += 1
        duplicateCache.removeAll()
        rootVisibility.removeAll()
        rootVisibilityAsked.removeAll()
        rootVisibilityReadAt.removeAll()
        rootVisibilityOrder.removeAll()
        rootVisibilityPositions.removeAll()
        stateRefreshes.removeAll()
        primingCancellation = nil
        // Don't cancel running lookups (their callers still get server truth as of their start),
        // but stop new callers from joining them and stop their results from repopulating the
        // invalidated cache (guarded by `cacheGeneration` in `lookup`).
        inFlight.removeAll()
    }

    /// Batch-prefetch for a fresh enqueue: computes name hashes (no content hashing) and queries
    /// the duplicates endpoint in Proton-sized chunks, so per-item `resolve` calls become cache
    /// hits. Clears only the short-lived name view. The backend's expensive account-wide content
    /// index has its own freshness window and must not be rebuilt every lookahead batch.
    public func prime(_ descriptors: [UploadResourceDescriptor]) async {
        invalidateNameCache()
        let generation = cacheGeneration
        let sources = Set(descriptors.map(\.source))
        let epoch: String
        do {
            try Task.checkCancellation()
            epoch = try await checker.hashKeyEpoch()
            try Task.checkCancellation()
        } catch {
            if generation == cacheGeneration, UploadError.isCancellation(error) {
                primingCancellation = (error, sources)
            }
            return
        }

        var pending: [String] = []
        var pendingSet: Set<String> = []
        var correctedNamesToHash: [String] = []
        var correctedNamesToHashSet: Set<String> = []
        // The names of the roots in the order of `descriptors`, see `rootEligible`. Their active rows get one
        // batched visibility read below.
        var rootNameHashes: [String] = []
        var rootNameHashSet: Set<String> = []
        var rootCorrectedNames: Set<String> = []

        func appendRootNameHash(_ hash: String) {
            if rootNameHashSet.insert(hash).inserted { rootNameHashes.append(hash) }
        }

        func appendPendingHash(_ hash: String) {
            if duplicateCache[hash] == nil, inFlight[hash] == nil, pendingSet.insert(hash).inserted {
                pending.append(hash)
            }
        }

        for descriptor in descriptors {
            let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
            let isRoot = descriptor.source.resource == .primary && descriptor.mainRemoteLinkID == nil
            let cached = store.record(for: descriptor.source)
            let hmacReusable =
                cached.map { $0.isValid(for: descriptor, hashKeyEpoch: epoch) && $0.correctedName == corrected }
                ?? false

            let nameHash: String
            if let cached, hmacReusable {
                // Fast-path rows won't query at resolve time either - skip them here too.
                if let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
                    outcome == .uploaded || outcome == .duplicateActive, cached.remoteLinkID != nil
                {
                    continue
                }
                nameHash = cached.nameHash
            } else {
                if correctedNamesToHashSet.insert(corrected).inserted {
                    correctedNamesToHash.append(corrected)
                }
                if isRoot { rootCorrectedNames.insert(corrected) }
                continue
            }
            if isRoot { appendRootNameHash(nameHash) }
            appendPendingHash(nameHash)
        }

        if !correctedNamesToHash.isEmpty {
            do {
                let hashes = try await checker.nameHashes(forCorrectedNames: correctedNamesToHash)
                try Task.checkCancellation()
                if hashes.count == correctedNamesToHash.count {
                    for (corrected, hash) in zip(correctedNamesToHash, hashes) {
                        if rootCorrectedNames.contains(corrected) { appendRootNameHash(hash) }
                        appendPendingHash(hash)
                    }
                }
            } catch {
                if generation == cacheGeneration, UploadError.isCancellation(error) {
                    primingCancellation = (error, sources)
                    return
                }
            }
        }

        let chunks = stride(from: 0, to: pending.count, by: batchSize).map { start in
            Array(pending[start..<min(start + batchSize, pending.count)])
        }
        await withTaskGroup(of: Int.self) { group in
            var nextChunk = 0

            func submitNext() {
                guard nextChunk < chunks.count, primingCancellation == nil, !Task.isCancelled else { return }
                let index = nextChunk
                nextChunk += 1
                group.addTask { [self] in
                    await primeLookup(batch: chunks[index], generation: generation, sources: sources)
                    return index
                }
            }

            for _ in 0..<min(Self.primeLookupConcurrency, chunks.count) {
                submitNext()
            }
            while await group.next() != nil {
                submitNext()
            }
        }
        guard generation == cacheGeneration, primingCancellation == nil else { return }
        await primeRootVisibility(ofNameHashes: rootNameHashes, sources: sources)
        if generation == cacheGeneration, Task.isCancelled { primingCancellation = (CancellationError(), sources) }
    }

    private func primeLookup(batch: [String], generation: Int, sources: Set<UploadSourceIdentity>) async {
        do {
            try Task.checkCancellation()
            _ = try await lookup(batch: batch)
            try Task.checkCancellation()
        } catch {
            if generation == cacheGeneration, UploadError.isCancellation(error) {
                primingCancellation = (error, sources)
            }
        }
    }

    /// Reads the role of every active row under the names of the upcoming roots, in batches of at most
    /// `batchSize` links: Proton's `links/fetch_metadata` takes 150 links per request, like the duplicates
    /// endpoint. The content hash of a new item is unknown before hashing, so every active row of the name
    /// counts. An ordinary failed batch counts as asked: its rows stay as listed, and a name row of it is read
    /// again before it counts as a backup. Cancellation instead stays deferred in this view and propagates at
    /// resolve.
    private func primeRootVisibility(
        ofNameHashes nameHashes: [String], sources: Set<UploadSourceIdentity>
    ) async {
        let generation = cacheGeneration
        var links: [String] = []
        var seen = rootVisibilityAsked
        for row in nameHashes.flatMap({ duplicateCache[$0] ?? [] }) where row.linkState == .active {
            if let linkID = row.linkID, seen.insert(linkID).inserted { links.append(linkID) }
        }
        for linkID in links where rootVisibilityPositions[linkID] == nil {
            rootVisibilityPositions[linkID] = rootVisibilityOrder.count
            rootVisibilityOrder.append(linkID)
        }
        for start in stride(from: 0, to: links.count, by: batchSize) {
            let chunk = Array(links[start..<min(start + batchSize, links.count)])
            let read: [String: RemoteLinkVisibility]
            var answeredAt: Date?
            do {
                try Task.checkCancellation()
                read = try await checker.linkVisibility(of: chunk)
                answeredAt = now()
            } catch {
                guard generation == cacheGeneration else { return }
                if Task.isCancelled || UploadError.isCancellation(error) {
                    primingCancellation = (Task.isCancelled ? CancellationError() : error, sources)
                    return
                }
                read = [:]
            }
            guard generation == cacheGeneration else { return }
            rootVisibilityAsked.formUnion(chunk)
            if let answeredAt {
                // A complete answer replaces every link of the chunk, also one that the answer leaves out.
                for linkID in chunk {
                    rootVisibility[linkID] = read[linkID]
                    rootVisibilityReadAt[linkID] = answeredAt
                }
            }
        }
    }

    public func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        do {
            let epoch = try await checker.hashKeyEpoch()
            try persistRecord(
                UploadIdentityRecord(
                    source: descriptor.source,
                    filename: descriptor.filename,
                    correctedName: identity.correctedName,
                    fileSize: descriptor.fileSize,
                    modificationDate: descriptor.modificationDate,
                    sha1Hex: identity.sha1Hex,
                    nameHash: identity.nameHash,
                    contentHash: identity.contentHash,
                    hashKeyEpoch: epoch,
                    remoteVolumeID: remoteVolumeID,
                    remoteLinkID: remoteLinkID,
                    outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue,
                    updatedAt: now()
                ))
        } catch {
            await invalidateCachedRemoteState()
            releasePendingUploadClaims(ownedBy: descriptor)
            throw error
        }
        await checker.recordUploaded(contentHash: identity.contentHash, remoteLinkID: remoteLinkID)
        // The server now has this name and content active. A cached "free" view for this name hash
        // must not survive the upload it predates.
        duplicateCache[identity.nameHash, default: []].append(
            RemotePhotoDuplicate(
                nameHash: identity.nameHash,
                contentHash: identity.contentHash,
                linkState: .active,
                linkID: remoteLinkID
            ))
        // Settle the same-content claim after the manifest row exists, so released waiters find
        // it. Owner-scoped scan (not key computation) so a failed epoch fetch can never leak the
        // claim and hang waiters.
        releasePendingUploadClaims(ownedBy: descriptor)
    }

    /// Reports that an upload attempt for a `.upload` decision ended without success (error,
    /// cancel, or stop). Drops the cached remote view (the server may have committed the attempt
    /// even though the call failed) and releases the same-content claim so identical waiting
    /// items re-resolve against fresh state.
    public func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        await invalidateCachedRemoteState()
        releasePendingUploadClaims(ownedBy: descriptor)
    }

    public func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        await invalidateCachedRemoteState()
        releasePendingUploadClaims(ownedBy: descriptor)
    }

    private func releasePendingUploadClaims(ownedBy owner: UploadResourceDescriptor) {
        for (key, pending) in pendingContentUploads where pending.owner.isValid(for: owner) {
            pendingContentUploads[key] = nil
            for waiter in pending.waiters.values { waiter.resume() }
        }
        for (key, pending) in pendingNameUploads where pending.owner.isValid(for: owner) {
            pendingNameUploads[key] = nil
            for waiter in pending.waiters.values { waiter.resume() }
        }
    }

    // MARK: - Duplicate lookup (cached / coalesced / batched)

    private func duplicates(forNameHash nameHash: String) async throws -> [RemotePhotoDuplicate] {
        if let hit = duplicateCache[nameHash] { return hit }
        if let running = inFlight[nameHash] {
            return try await running.value[nameHash] ?? []
        }
        return try await lookup(batch: [nameHash])[nameHash] ?? []
    }

    private func lookup(batch nameHashes: [String]) async throws -> [String: [RemotePhotoDuplicate]] {
        let checker = self.checker
        let generation = cacheGeneration
        let task = Task { () -> [String: [RemotePhotoDuplicate]] in
            let items = try await checker.findDuplicates(nameHashes: nameHashes)  // step 5: the one network call
            // Every requested hash gets an entry - [] distinguishes "server says free" from
            // "never asked" in the cache.
            var grouped = Dictionary(uniqueKeysWithValues: nameHashes.map { ($0, [RemotePhotoDuplicate]()) })
            for item in items { grouped[item.nameHash, default: []].append(item) }
            return grouped
        }
        for hash in nameHashes { inFlight[hash] = task }
        defer {
            for hash in nameHashes where inFlight[hash] == task { inFlight[hash] = nil }
        }
        let grouped = try await task.value
        // A view invalidated while this lookup ran must stay invalidated - the result predates it.
        if generation == cacheGeneration {
            for (hash, items) in grouped { duplicateCache[hash] = items }
        }
        return grouped
    }
}

/// The earlier uploads of one primary that an edit replaces (`superseded`) or already replaced (`retired`), and the
/// earlier uploads that left the library without a known author (`gone`).
private struct UploadReplacementScope {
    var superseded: Set<String>
    var retired: Set<String>
    /// The photo that showed before this upload: the last upload that the manifest names, else the newest
    /// superseded photo of the journal.
    var current: String?
    var gone: Set<String> = []
    var knownForeignLinks: Set<String> = []
    var liveHeads: Set<String> = []
    /// A same-identity head that is not older than this edit. It proves the photo live and is never a target.
    var keptHeads: Set<String> = []
    var remoteAncestors: Set<String> = []
    var candidateVisibility: [String: RemoteLinkVisibility]?

    var isEmpty: Bool { superseded.isEmpty && retired.isEmpty && gone.isEmpty }
}
