import AVFoundation
import AlbumCore
import Foundation
import PhotosCore
import ProtonAuth
import ProtonDriveSDK
import UploadCore

private typealias LibraryPhotoTag = PhotosCore.PhotoTag

/// Bridges the feature modules to the Proton Drive SDK. Owns the `EncryptedMemoriesClient`, wires in
/// our HTTP + account clients, resolves the photos root, and adapts SDK types to `PhotosCore`.
///
/// Everything SDK-specific is isolated here so feature modules stay SDK-agnostic and new SDK
/// capabilities (albums, sharing, upload) can be added without touching the UI layer.
actor DriveSDKBridge: PhotosRepository, LibraryChangeTokenProvider, ThumbnailProvider, ThumbnailBatchLoader,
    PriorityThumbnailBatchLoader, FullMediaProvider, OriginalByteStreamProvider, OriginalFileProvider,
    VideoStreamProvider, PhotoMetadataProvider, BurstGroupProvider, PhotoLibraryProvider, FavoritesProvider,
    PhotoLibrarySaving, TrashProvider, LibraryStatsProvider
{
    private let photosClient: EncryptedMemoriesClient
    private let uploadClientUID: String
    private let driveSession: DriveSession
    private let requestGovernor = ProtonRequestGovernor()
    private nonisolated let sharedAlbumSnapshotCache = SDKSharedAlbumSnapshotCache()
    private var photosRoot: SDKNodeUid?
    private var photosShareID: String?
    /// App-owned SQLite timeline metadata store (`library-v1.sqlite`, PhotosCore). The bridge is
    /// the macOS adapter: it chooses the path + desktop SQLite tuning and injects both; schema and
    /// save/load logic live in Core.
    private let timelineStore: TimelineMetadataStore?
    /// Drive key-derivation + block decryption for video streaming (built once at sign-in).
    private let crypto: DriveCrypto
    private let photosVolumeBootstrap: PhotosVolumeBootstrapService
    private var streamSource: PhotoVideoStreamSource?
    /// Reused by burst viewer opens after the timeline enrichment already paid for the server listing.
    /// A timeline refresh replaces it atomically; a lookup miss fetches once to cover a newly-arrived burst.
    private var burstCatalogEntries: [PhotosListEntry]?
    private var burstCatalogLookup: [String: [String]] = [:]
    /// The related files of a series that the viewer checked for a frame type, so a reopen reads no metadata again.
    private var burstFrameVerdicts = BurstFrameVerdicts()
    /// The types of related files that chose the motion of a Live Photo, so a refresh reads no metadata again.
    private var livePhotoMotionLinks = LivePhotoMotionLinks()
    /// Account-scoped single flight for authoritative enumeration. Actor reentrancy alone does not serialize
    /// work across awaits; without this, foreground lifecycle, upload refresh and a second Mac window can all
    /// enumerate the same 20k-item library concurrently.
    private var timelineLoadTask: (generation: UInt64, task: Task<TimelineLoadSnapshot, any Error>)?
    private var timelineLoadGeneration: UInt64 = 0
    /// Three-pass quiet-window proof for a full Photos listing after event history becomes unusable. This state
    /// is intentionally memory-only; a relaunch restarts proof instead of trusting a partially observed window.
    private var continuityRecovery = TimelineContinuityRecoveryCoordinator()
    /// Primary uploads returned by the SDK but not yet observed in an authoritative photos listing.
    private var pendingUploadedNodeIDs = Set<String>()
    /// Low-priority, resumable reconciliation of lossy timeline tags with authoritative link MIME types.
    /// One task per bridge keeps lifecycle refreshes from starting duplicate scans.
    private var mediaTypeReconciliationTask: Task<Void, Never>?
    private var isShutDown = false
    private nonisolated let shutdownGate = JoinedShutdownGate()
    /// Receives the identities of a listing that no source inventory contains, currently the volume trash.
    /// The library source coordinator authorizes their thumbnails; without it every tile stays black.
    private nonisolated let identitiesOutsideInventoryObserver = IdentitiesOutsideInventoryObserver()
    /// The last Recently Deleted listing on disk, so the route opens offline and its thumbnails survive a launch.
    private let recentlyDeletedStore: RecentlyDeletedListingStore
    private var librarySupport = LibrarySyncSupportSnapshot()
    private var recentlyDeleted: RecentlyDeletedIdentities
    /// Low-priority trash listing after the library lost photos, so photos trashed elsewhere get their
    /// thumbnails before the route opens. One task per bridge.
    private var trashListingTask: Task<Void, Never>?
    /// Orders identity reports: the coordinator applies only a report newer than the last one it applied, so a
    /// report that an actor hop delayed cannot replace a newer list.
    private var recentlyDeletedReportSequence: UInt64 = 0

    /// Set by a timeline save that removed photos; a trash listing then follows the load.
    private var timelineLostPhotos = false
    /// Bytes this session uploaded, and the part of them that the latest account refresh already contains: the
    /// uploads recorded before that refresh started. The capacity check subtracts the rest from the account quota.
    private var uploadedBytes: Int64 = 0
    private var uploadedBytesInQuota: Int64 = 0
    private var quotaRefresh: Task<Void, Never>?
    private var quotaRefreshWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lastQuotaRefreshAt: ContinuousClock.Instant?
    /// Where the per-account upload-identity manifest lives (next to `library-v1.sqlite`, so the
    /// sign-out purge covers it) and the platform SQLite tuning it opens with. Module-internal:
    /// the facade derives the account data directory + store policy for the backup sync stores
    /// (same directory, same purge coverage).
    let uploadManifestURL: URL
    let uploadManifestPolicy: LibraryDatabasePolicy

    /// Full sign-out / master-reset: erase the SDK metadata SQLite stores for `uid` (security
    /// follow-up #2 - non-secret node metadata that must not survive sign-out) AND the app-owned
    /// `library-v1.sqlite` account directory. The encrypted caches, video blocks, and account-data
    /// cache are erased by their own paths; this covers the remaining account-tied data at rest.
    /// Wired from `AppModel.signOut`.
    static func purgeMetadata(uid: String, policy: ProtonDriveBackendPolicy) {
        SDKMetadataStore.purgeMetadata(in: policy.sdkCacheDirectory, uid: uid)
        LibraryDatabaseLocation.purgeAccountData(uid: uid, in: policy.libraryDatabaseBaseDirectory)
    }

    init(
        session: ProtonSession,
        store: SessionKeychainStore,
        policy: ProtonDriveBackendPolicy,
        deviceIdentityStore: DeviceIdentityKeychainStore = DeviceIdentityKeychainStore()
    ) async throws {
        await MainActor.run {
            AccountInfo.shared.beginSession(accountUID: session.uid)
        }
        let driveSession = DriveSession(
            session: session,
            store: store,
            config: .externalDriveEncryptedMemories,
            accountCacheDirectory: policy.sdkCacheDirectory,
            requestGovernor: requestGovernor
        )
        self.driveSession = driveSession

        DebugLog.log("bridge: fetching account data…")
        // Build the account client (fetch + decrypt the user's keys) up front. If the network is unavailable
        // (cold offline launch), fall back to the encrypted account cache persisted on a previous online launch,
        // so the library still opens (read-only, on cached data) instead of failing the whole signed-in UI.
        let account: AccountData
        do {
            account = try await driveSession.fetchAccountData()
            DebugLog.log(
                "bridge: account ok - \(account.addresses.count) addresses, \(account.userKeys.count) user keys")
        } catch {
            guard let cached = await driveSession.cachedAccountData() else { throw error }
            account = cached
            DebugLog.log("bridge: OFFLINE - using cached account data (\(cached.addresses.count) addresses)")
        }
        let accountClient = try SDKAccountClientBuilder.build(account: account, keyPassword: session.keyPassword)
        DebugLog.log("bridge: account client built (\(accountClient.unlockedByKeyID.count) unlocked keys)")

        // Crypto for streaming: the same address keys, kept as (armored, passphrase) so we can
        // derive share/node keys and the per-file content session key on demand.
        let crypto = DriveCrypto(account: account, keyPassword: session.keyPassword)
        self.crypto = crypto
        self.photosVolumeBootstrap = PhotosVolumeBootstrapService(session: driveSession, crypto: crypto)

        let caches = policy.sdkCacheDirectory
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        // Persisted timeline (per account) for instant startup. The store lives in PhotosCore at
        // Application Support/EncryptedMemories/<uid>/library-v1.sqlite (backup-excluded, re-derivable).
        let libraryDirectory = LibraryDatabaseLocation.prepareAccountDirectory(
            uid: session.uid,
            in: policy.libraryDatabaseBaseDirectory
        )
        self.timelineStore = TimelineMetadataStore(
            url: libraryDirectory.appendingPathComponent(LibraryDatabaseLocation.databaseFileName),
            policy: policy.libraryDatabasePolicy
        )
        self.uploadManifestURL = libraryDirectory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let recentlyDeletedStore = RecentlyDeletedListingStore(
            directory: libraryDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword
        )
        self.recentlyDeletedStore = recentlyDeletedStore
        self.recentlyDeleted = RecentlyDeletedIdentities(persisted: recentlyDeletedStore.load() ?? .init())
        self.uploadManifestPolicy = policy.libraryDatabasePolicy
        // Keep the optional native SDK cache in memory. SDK 0.29.1 only frees the managed client handle;
        // it does not deterministically dispose its SQLite repository. A persistent native cache can therefore
        // still own WAL files after shutdown and makes the required same-process sign-out purge unsafe.
        // The app-owned encrypted account cache and timeline store provide offline and warm-launch persistence.
        let uploadClientUID = UploadClientIdentity.make(
            accountUID: session.uid,
            deviceIdentifier: deviceIdentityStore.loadOrCreate()
        )
        self.uploadClientUID = uploadClientUID
        let uploadBufferSize = UploadTransportBufferPolicy.bufferSize()
        let config = ProtonDriveClientConfiguration(
            baseURL: "https://drive-api.proton.me/",  // trailing slash required by the C# core
            clientUID: uploadClientUID,
            httpTransferBufferSize: uploadBufferSize,
            boundStreamsCreator: {
                try UploadTransportBufferPolicy.makeBoundStreams(bufferSize: uploadBufferSize)
            }
        )
        self.photosClient = try await EncryptedMemoriesClient(
            configuration: config,
            httpClient: SDKHttpClient(driveSession: driveSession, requestGovernor: requestGovernor),
            accountClient: accountClient,
            logCallback: { _ in },
            featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in }
        )
        SupportDiagnosticsSources.shared.registerLibrary(self)
        DebugLog.log("bridge: EncryptedMemoriesClient created ✓")
    }

    /// Ends account-scoped work and closes every SQLite owner before sign-out removes the account
    /// directory. Actor isolation orders this behind any operation currently using the stores.
    func shutdown() async {
        if !isShutDown {
            isShutDown = true
            SupportDiagnosticsSources.shared.unregisterLibrary(self)
            timelineLoadGeneration &+= 1
            shutdownGate.closeAdmission()
            timelineLoadTask?.task.cancel()
            mediaTypeReconciliationTask?.cancel()
            trashListingTask?.cancel()
            quotaRefresh?.cancel()
        }
        await shutdownGate.run { [weak self] in
            await self?.performShutdown()
        }
    }

    private nonisolated func withOpenSession<T: Sendable>(
        _ operation: @escaping @Sendable (isolated DriveSDKBridge) async throws -> T
    ) async throws -> T {
        try await shutdownGate.withAdmission { [self] in
            try await operation(self)
        }
    }

    private func performShutdown() async {
        // Admission is closed and every published operation has settled before this teardown runs.
        // Drain cache-owned SDK tasks now, including flights orphaned by admission cancellation.
        await sharedAlbumSnapshotCache.invalidateAll()

        let timelineTask = timelineLoadTask?.task
        timelineLoadTask = nil
        timelineTask?.cancel()

        let reconciliationTask = mediaTypeReconciliationTask
        mediaTypeReconciliationTask = nil
        reconciliationTask?.cancel()
        let trashTask = trashListingTask
        trashListingTask = nil
        trashTask?.cancel()

        _ = await timelineTask?.result
        await reconciliationTask?.value
        await trashTask?.value
        timelineStore?.close()
        await photosClient.shutdown()
    }

    // MARK: - PhotosRepository

    func loadTimeline() async throws -> [TimelineSection] {
        try await withOpenSession { bridge in
            try await bridge.loadTimelineSnapshotImpl().sections
        }
    }

    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        try await withOpenSession { bridge in
            try await bridge.loadTimelineSnapshotImpl()
        }
    }

    private func loadTimelineSnapshotImpl() async throws -> TimelineLoadSnapshot {
        guard !isShutDown else { throw CancellationError() }
        if let timelineLoadTask {
            return try await timelineLoadTask.task.value
        }

        timelineLoadGeneration &+= 1
        let generation = timelineLoadGeneration
        let task = Task { try await self.performTimelineLoad(generation: generation) }
        timelineLoadTask = (generation, task)
        do {
            let snapshot = try await task.value
            if timelineLoadTask?.generation == generation { timelineLoadTask = nil }
            return snapshot
        } catch {
            if timelineLoadTask?.generation == generation { timelineLoadTask = nil }
            throw error
        }
    }

    private func performTimelineLoad(generation: UInt64) async throws -> TimelineLoadSnapshot {
        var supportSource = LibrarySyncSupportSnapshot.SourcePath.preparation
        do {
            try checkTimelineLoad(generation: generation)
            let root = try await resolvePhotosRoot()
            try checkTimelineLoad(generation: generation)
            // Keep the previous rows + token intact while network work is in flight. The final SQLite save
            // atomically replaces both only after the enumeration is complete and stable; cancellation, process
            // death or a transient endpoint failure therefore cannot poison the next warm launch.
            let cachedValidationToken = timelineStore?.validationToken()
            let cachedEventToken = TimelineInventoryValidationTokenPolicy.remoteEventToken(
                from: cachedValidationToken
            )
            let historyEventProbe = try await volumeEventProbe(
                volumeID: root.volumeID,
                cursor: cachedEventToken,
                priority: .userInitiated
            )
            if historyEventProbe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
            var continuityRecoveryRequired = historyEventProbe.requiresAuthoritativeRefresh
            if continuityRecoveryRequired { supportSource = .continuity }
            let startEventProbe: SDKEventCursorResult
            if continuityRecoveryRequired {
                // A continuity event is not a committable cursor. Seed a fresh current cursor, then prove a
                // complete server listing against it over the bounded quiet window below.
                startEventProbe = try await volumeEventProbe(
                    volumeID: root.volumeID,
                    cursor: nil,
                    priority: .userInitiated
                )
                guard !startEventProbe.requiresAuthoritativeRefresh else {
                    continuityRecovery.reset()
                    throw TimelineContinuityRecoveryPendingError()
                }
            } else {
                startEventProbe = historyEventProbe
            }
            let startEventToken = try eventCursor(from: startEventProbe)
            try checkTimelineLoad(generation: generation)
            DebugLog.log("timeline: photos root \(root.volumeID.prefix(8))…/\(root.nodeID.prefix(8))… - enumerating")
            let mediaTypeEvidence = timelineStore?.mediaTypeEvidence(volumeID: root.volumeID) ?? [:]
            let currentValidationToken = TimelineInventoryValidationTokenPolicy.persistedToken(
                remoteEventToken: startEventToken
            )
            let unmaterializedEvidenceNodeIDs =
                timelineStore?.unmaterializedMediaTypeEvidenceNodeIDs(
                    volumeID: root.volumeID
                ) ?? []
            var enrichmentComplete = true
            let source =
                continuityRecoveryRequired
                ? TimelineInventorySource.authoritativePhotosList
                : TimelineInventorySourcePolicy.decide(
                    cachedEventToken: cachedValidationToken,
                    currentEventToken: currentValidationToken,
                    hasPendingLocalUploads: !pendingUploadedNodeIDs.isEmpty,
                    hasUnmaterializedLocalEvidence: !unmaterializedEvidenceNodeIDs.isEmpty
                )
            var sections: [TimelineSection]
            var reconciliationItems: [PhotoItem]
            var burstMemberIDs: [String: [String]]
            var burstEntries: [PhotosListEntry]?
            var authoritativeInventoryFingerprint: String?
            // Only while photos trashed here or removed by an event may still appear in a listing.
            var listingRead: LibraryListingRead?
            let listingReadAt = Date()

            switch source {
            case .authoritativePhotosList:
                supportSource = continuityRecoveryRequired ? .continuity : .authoritative
                let remoteChanges: TimelineRemoteEventChanges?
                if continuityRecoveryRequired {
                    remoteChanges = nil
                } else {
                    remoteChanges = try await remoteEventChanges(
                        since: cachedEventToken,
                        currentEventToken: startEventToken,
                        volumeID: root.volumeID
                    )
                    if remoteChanges == nil {
                        continuityRecoveryRequired = true
                        supportSource = .continuity
                    }
                }
                // This load moves the event cursor past these events, while the next listing can still return the
                // removed files. The waits are saved before the cursor moves, so a relaunch keeps them.
                let removalsChanged =
                    if let remoteChanges {
                        recentlyDeleted.eventsRead(remoteChanges, volumeID: root.volumeID, at: listingReadAt)
                    } else {
                        recentlyDeleted.eventsLost()
                    }
                if removalsChanged { recentlyDeletedStore.save(recentlyDeleted.persisted) }
                var entries: [PhotosListEntry]
                if continuityRecoveryRequired {
                    entries = try await continuityRecovery.fetchInventory(
                        cursor: startEventToken,
                        now: .now
                    ) { [driveSession] in
                        try await driveSession.fetchPhotosList(volumeID: root.volumeID)
                    }
                } else {
                    entries = try await driveSession.fetchPhotosList(volumeID: root.volumeID)
                }
                librarySupport.listedPhotoCount = entries.count
                if recentlyDeleted.hasPhotosAwaitingLibrary {
                    // Read before the events below filter the listing: a photo that they leave out must still
                    // wait, as the next listing can return it without that event.
                    listingRead = LibraryListingRead(
                        listed: Set(entries.map { PhotoUID(volumeID: root.volumeID, nodeID: $0.linkID) }),
                        restoredElsewhere: Set(
                            (remoteChanges?.active ?? []).map { PhotoUID(volumeID: root.volumeID, nodeID: $0) }),
                        readAt: listingReadAt)
                }
                // The listing can return a photo for a short time after it moved to the trash, for example the
                // earlier upload that the backup just replaced. The newer events decide.
                if let removed = remoteChanges?.removed, !removed.isEmpty {
                    entries.removeAll { removed.contains($0.linkID) }
                }
                authoritativeInventoryFingerprint = TimelineContinuityInventoryFingerprint.make(entries: entries)
                let representedNodeIDs = Set(entries.map(\.linkID)).union(
                    entries.flatMap { $0.relatedPhotos.map(\.linkID) }
                )
                if let expectedRemoteNodeIDs = remoteChanges?.active {
                    let missing = expectedRemoteNodeIDs.subtracting(representedNodeIDs)
                    if !missing.isEmpty {
                        let awaited = try await filesTheListingMustShow(missing)
                        guard awaited.isEmpty else {
                            throw TimelineInventoryVisibilityError.remoteChangesNotVisible(awaited.count)
                        }
                        DebugLog.log(
                            "timeline: \(missing.count) changed files belong to photos that left the library")
                    }
                }
                pendingUploadedNodeIDs.subtract(representedNodeIDs)
                let unresolvedEvidenceNodeIDs = unmaterializedEvidenceNodeIDs.subtracting(representedNodeIDs)
                // An upload whose photo left the library before a listing showed it, such as an edit that a later
                // edit replaced, never shows; only uploads that can still show hold the load back.
                let unlistedUploads = pendingUploadedNodeIDs.union(unresolvedEvidenceNodeIDs)
                pendingUploadedNodeIDs =
                    unlistedUploads.isEmpty ? [] : try await filesTheListingMustShow(unlistedUploads)
                burstMemberIDs = Self.burstMemberLookup(from: entries)
                burstEntries = entries
                let motions = try await livePhotoMotions(
                    of: Self.livePhotos(in: entries), volumeID: root.volumeID, evidence: mediaTypeEvidence)
                sections = Self.group(
                    entries,
                    volumeID: root.volumeID,
                    mediaTypeOverrides: mediaTypeEvidence,
                    motions: motions,
                    sectionID: "all"
                )
                reconciliationItems = sections.flatMap(\.items)
                DebugLog.log("timeline: authoritative photos listing returned \(reconciliationItems.count) items ✓")

            case .sdkCache:
                supportSource = .sdkCache
                let collector = SDKEnumerationCollector<PhotoTimelineItem>()
                let items = try await SDKCancellableOperation.run { [photosClient] cancellationToken in
                    try await photosClient.enumerateTimeline(
                        in: root,
                        cancellationToken: cancellationToken,
                        onPhotoEnumerated: { result in collector.receive(result) }
                    )
                    return try collector.collected()
                } cancel: { [photosClient] cancellationToken in
                    try? await photosClient.cancelEnumerateTimeline(cancellationToken: cancellationToken)
                }
                try checkTimelineLoad(generation: generation)
                librarySupport.listedPhotoCount = items.count
                DebugLog.log("timeline: SDK cache enumerated \(items.count) items ✓")
                let enrichment = await TimelineTagEnrichmentLoader.load {
                    [driveSession, volumeID = root.volumeID] tag, onPage in
                    try await driveSession.forEachPhotosListPage(
                        volumeID: volumeID,
                        tag: tag.rawValue,
                        onPage: onPage
                    )
                }
                try checkTimelineLoad(generation: generation)
                if enrichment.wasCancelled { throw CancellationError() }

                let videoNodeIDs: Set<String>
                if let videos = enrichment.videos.value {
                    videoNodeIDs = videos
                } else {
                    videoNodeIDs = []
                    enrichmentComplete = false
                    if let error = enrichment.videos.errorDescription {
                        DebugLog.log("timeline: video tag enrichment skipped - \(error)")
                    }
                }
                var liveMotions: [String: LivePhotoMotion] = [:]
                if let lives = enrichment.livePhotos.value {
                    liveMotions = try await livePhotoMotions(
                        of: lives, volumeID: root.volumeID, evidence: mediaTypeEvidence)
                } else {
                    enrichmentComplete = false
                    if let error = enrichment.livePhotos.errorDescription {
                        DebugLog.log("timeline: live-photo tag enrichment skipped - \(error)")
                    }
                }
                if let bursts = enrichment.bursts.value {
                    burstMemberIDs = Self.burstMemberLookup(from: bursts)
                    burstEntries = bursts
                } else {
                    burstMemberIDs = [:]
                    burstEntries = nil
                    enrichmentComplete = false
                    if let error = enrichment.bursts.errorDescription {
                        DebugLog.log("timeline: burst tag enrichment skipped - \(error)")
                    }
                }
                sections = Self.group(
                    items,
                    videoNodeIDs: videoNodeIDs,
                    mediaTypeOverrides: mediaTypeEvidence,
                    livePhotoMotions: liveMotions,
                    burstMemberIDs: burstMemberIDs
                )
                reconciliationItems = sections.flatMap(\.items)
                if recentlyDeleted.hasPhotosAwaitingLibrary {
                    listingRead = LibraryListingRead(listed: Set(reconciliationItems.map(\.uid)), readAt: listingReadAt)
                }
            }
            try checkTimelineLoad(generation: generation)
            guard pendingUploadedNodeIDs.isEmpty else {
                throw TimelineInventoryVisibilityError.pendingUploadsNotVisible(pendingUploadedNodeIDs.count)
            }
            if let listingRead {
                let lagging = recentlyDeleted.lagging(in: listingRead, now: Date())
                if !lagging.isEmpty {
                    DebugLog.log("timeline: left out \(lagging.count) photos that the listing returns after a trash")
                    let kept = Self.removing(lagging, from: sections, burstEntries: burstEntries)
                    sections = kept.sections
                    // The media-type check and the burst catalog must not keep them either.
                    reconciliationItems = sections.flatMap(\.items)
                    if let entries = kept.burstEntries {
                        burstEntries = entries
                        burstMemberIDs = Self.burstMemberLookup(from: entries)
                    }
                }
            }
            var continuityRecoveryQualified = false
            let endEventToken: String
            if continuityRecoveryRequired {
                guard let authoritativeInventoryFingerprint else {
                    continuityRecovery.reset()
                    throw TimelineContinuityRecoveryPendingError()
                }
                let qualification = try await continuityRecovery.qualify(
                    startCursor: startEventToken,
                    inventoryFingerprint: authoritativeInventoryFingerprint,
                    now: .now
                ) { [self] in
                    let probe = try await volumeEventProbe(
                        volumeID: root.volumeID,
                        cursor: startEventToken,
                        priority: .userInitiated
                    )
                    return TimelineContinuityPostInventoryProbe(
                        cursor: try eventCursor(from: probe),
                        requiresAuthoritativeRefresh: probe.requiresAuthoritativeRefresh
                    )
                }
                endEventToken = qualification.endCursor
                continuityRecoveryQualified = qualification.recoveryQualified
            } else {
                let endEventProbe = try await volumeEventProbe(
                    volumeID: root.volumeID,
                    cursor: startEventToken,
                    priority: .userInitiated
                )
                endEventToken = try eventCursor(from: endEventProbe)
                // A new continuity loss during enumeration starts a fresh proof window on the next load. Do not
                // return a successful memory-only snapshot because the monitor would consume its probed token.
                guard !endEventProbe.requiresAuthoritativeRefresh else {
                    continuityRecovery.reset()
                    throw TimelineContinuityRecoveryPendingError()
                }
                continuityRecovery.reset()
            }
            try checkTimelineLoad(generation: generation)
            let commit = TimelineLoadCommitPolicy.decide(
                startEventToken: startEventToken,
                endEventToken: endEventToken,
                enrichmentComplete: enrichmentComplete
            )
            if continuityRecoveryQualified, commit.persistedValidationToken == nil {
                throw TimelineContinuityRecoveryPendingError()
            }
            if let persistedToken = commit.persistedValidationToken {
                try checkTimelineLoad(generation: generation)
                let cacheSaved = try continuityRecovery.persist(
                    recoveryQualified: continuityRecoveryQualified
                ) {
                    writeTimelineCache(
                        sections,
                        validationToken: TimelineInventoryValidationTokenPolicy.persistedToken(
                            remoteEventToken: persistedToken
                        )
                    )
                }
                if source == .authoritativePhotosList, cacheSaved,
                    timelineStore?.pruneUnmaterializedMediaTypeEvidence(volumeID: root.volumeID) == false
                {
                    DebugLog.log("timeline: stale media-type evidence cleanup failed")
                }
            } else {
                DebugLog.log("timeline: usable inventory kept in memory; incomplete enrichment will retry")
            }
            if let listingRead, recentlyDeleted.libraryAccepted(listingRead, now: Date()) {
                recentlyDeletedStore.save(recentlyDeleted.persisted)
            }
            if let burstEntries {
                burstCatalogEntries = burstEntries
                burstCatalogLookup = burstMemberIDs
            }
            scheduleMediaTypeReconciliation(
                items: reconciliationItems,
                alreadyClassifiedNodeIDs: Set(mediaTypeEvidence.keys)
            )
            // Read before the awaits below: the media-type reconciliation may publish a newer revision meanwhile,
            // and the token must describe the evidence these sections were grouped with.
            let validationToken = monitorToken(remoteToken: commit.monitorBaseline)
            if timelineLostPhotos {
                // Photos left the library, maybe into the trash on another device. List the trash before the caller
                // publishes the smaller library, so the cache sweep keeps the thumbnails of photos now in the trash.
                timelineLostPhotos = false
                do {
                    _ = try await listTrash()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A background listing repeats it; no refresh waits for a failing endpoint again.
                    recentlyDeleted.listingFailed()
                    DebugLog.log("trash: listing after a library change failed - \(error)")
                }
            } else {
                scheduleTrashListing()
            }
            if recentlyDeleted.hasRestoredPhotos {
                let libraryUIDs = Set(sections.lazy.flatMap(\.items).map(\.uid))
                if recentlyDeleted.libraryRefreshed(lists: libraryUIDs.contains) { await reportRecentlyDeleted() }
            }
            librarySupport.lastSuccessfulLoad = .init(timestamp: Date(), sourcePath: supportSource)
            recordSupportEvent(
                .libraryLoadSucceeded, sourcePath: supportSource, count: librarySupport.listedPhotoCount)
            return TimelineLoadSnapshot(sections: sections, validationToken: validationToken)
        } catch is TimelineContinuityRecoveryPendingError {
            librarySupport.lastFailedLoad = .init(
                timestamp: Date(), sourcePath: supportSource, errorKind: .continuityPending)
            recordSupportEvent(
                .libraryLoadFailed, sourcePath: supportSource, errorKind: .continuityPending)
            DebugLog.log("timeline: continuity recovery is still converging")
            throw TimelineContinuityRecoveryPendingError()
        } catch {
            let errorKind = Self.supportLoadErrorKind(error)
            librarySupport.lastFailedLoad = .init(timestamp: Date(), sourcePath: supportSource, errorKind: errorKind)
            recordSupportEvent(.libraryLoadFailed, sourcePath: supportSource, errorKind: errorKind)
            // A transport error, cancellation, or other invalid observation breaks the quiet window. A future
            // recovery attempt must collect all three qualified full inventories again.
            continuityRecovery.reset()
            DebugLog.log("timeline: FAILED - \(error)")
            throw error
        }
    }

    private func checkTimelineLoad(generation: UInt64) throws {
        try Task.checkCancellation()
        guard !isShutDown, timelineLoadGeneration == generation else {
            throw CancellationError()
        }
    }

    /// Last-known timeline from disk, for instant startup (no spinner). Reads from SQLite - then
    /// `loadTimeline()` refreshes in the background.
    func cachedTimeline() -> [TimelineSection]? {
        guard !isShutDown else { return nil }
        return cachedTimelineSnapshot()?.sections
    }

    func cachedTimelineSnapshot() -> CachedTimelineSnapshot? {
        guard !isShutDown else { return nil }
        guard let store = timelineStore else { return nil }
        let items = store.load()
        let validationToken = store.validationToken()
        guard !items.isEmpty || validationToken != nil else { return nil }
        librarySupport.lastSuccessfulLoad = .init(timestamp: Date(), sourcePath: .cache)
        recordSupportEvent(.libraryLoadSucceeded, sourcePath: .cache, count: items.count)
        DebugLog.log("timeline: served \(items.count) items from SQLite cache ✓")
        let sections =
            items.isEmpty
            ? []
            : [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
        return CachedTimelineSnapshot(sections: sections, validationToken: validationToken)
    }

    func cachedTimelineValidationToken() -> String? {
        guard !isShutDown else { return nil }
        return timelineStore?.validationToken()
    }

    /// One bounded SDK event probe. A changed cursor tells the shared foreground monitor to perform
    /// an authoritative timeline refresh; unchanged polls never enumerate or decrypt the library.
    func libraryChangeToken() async throws -> String {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            let cursor = TimelineInventoryValidationTokenPolicy.remoteEventToken(
                from: bridge.timelineStore?.validationToken()
            )
            let probe = try await bridge.volumeEventProbe(
                volumeID: root.volumeID,
                cursor: cursor,
                priority: .background
            )
            if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
            let remote: String
            if probe.requiresAuthoritativeRefresh {
                let seed = try await bridge.volumeEventProbe(
                    volumeID: root.volumeID,
                    cursor: nil,
                    priority: .background
                )
                guard !seed.requiresAuthoritativeRefresh else {
                    throw TimelineContinuityRecoveryPendingError()
                }
                remote = try bridge.eventCursor(from: seed)
            } else {
                remote = try bridge.eventCursor(from: probe)
            }
            return bridge.monitorToken(remoteToken: remote)
        }
    }

    func launchValidationToken() async throws -> String {
        try await withOpenSession { bridge in
            try await bridge.launchValidationTokenImpl()
        }
    }

    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String {
        try await withOpenSession { bridge in
            if let volumeID = snapshot.sections.lazy.flatMap(\.items).first?.uid.volumeID {
                let cursor = TimelineInventoryValidationTokenPolicy.remoteEventToken(
                    from: snapshot.validationToken
                )
                let probe = try await bridge.volumeEventProbe(
                    volumeID: volumeID,
                    cursor: cursor,
                    priority: .userInitiated
                )
                if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
                guard !probe.requiresAuthoritativeRefresh else {
                    throw TimelineContinuityRecoveryPendingError()
                }
                let remoteToken = try bridge.eventCursor(from: probe)
                return TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: remoteToken)
            }
            return try await bridge.launchValidationTokenImpl()
        }
    }

    private func launchValidationTokenImpl() async throws -> String {
        let root = try await resolvePhotosRoot()
        let cursor = TimelineInventoryValidationTokenPolicy.remoteEventToken(
            from: timelineStore?.validationToken()
        )
        let probe = try await volumeEventProbe(
            volumeID: root.volumeID,
            cursor: cursor,
            priority: .userInitiated
        )
        if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
        guard !probe.requiresAuthoritativeRefresh else {
            throw TimelineContinuityRecoveryPendingError()
        }
        let remoteToken = try eventCursor(from: probe)
        return TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: remoteToken)
    }

    private func volumeEventProbe(
        volumeID: String,
        cursor: String?,
        priority: ProtonRequestPriority
    ) async throws -> SDKEventCursorResult {
        let accumulator = SDKEventCursorAccumulator(cursor: cursor)
        return try await ProtonRequestContext.$priority.withValue(priority) {
            try await SDKCancellableOperation.run { [photosClient] cancellationToken in
                try await photosClient.enumerateEvents(
                    treeEventScopeId: volumeID,
                    cursor: cursor,
                    cancellationToken: cancellationToken,
                    onDriveEventEnumerated: { result in accumulator.receive(result) }
                )
                return try accumulator.result()
            } cancel: { [photosClient] cancellationToken in
                try? await photosClient.cancelEnumerateEvents(cancellationToken: cancellationToken)
            }
        }
    }

    private func eventCursor(from probe: SDKEventCursorResult) throws -> String {
        if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
        guard let cursor = probe.cursor else { throw SDKEventCursorError.missingCursor }
        return cursor
    }

    private func monitorToken(remoteToken: String) -> String {
        "\(remoteToken)#media=\(timelineStore?.mediaTypeEvidenceRevision() ?? 0)"
    }

    /// Returns the files that the events after the cached inventory token made active or removed. The Photos
    /// listing can lag the volume event feed: callers must not commit the new token until the active IDs are
    /// visible, and they drop the removed IDs from the listing. A server-requested full event refresh returns nil
    /// because no bounded event evidence remains to validate.
    private func remoteEventChanges(
        since cachedEventToken: String?,
        currentEventToken: String,
        volumeID: String
    ) async throws -> TimelineRemoteEventChanges? {
        guard let cachedEventToken,
            !cachedEventToken.isEmpty,
            cachedEventToken != currentEventToken,
            let photosShareID
        else { return TimelineRemoteEventChanges() }

        var eventID = cachedEventToken
        var changes = TimelineRemoteEventChanges()
        while true {
            try Task.checkCancellation()
            let page = try await driveSession.fetchVolumeEvents(volumeID: volumeID, since: eventID)
            if page.requiresRefresh { return nil }
            TimelineRemoteEventVisibilityPolicy.apply(
                page.events,
                photosShareID: photosShareID,
                to: &changes
            )
            eventID = page.eventID
            if !page.hasMore { return changes }
        }
    }

    /// Starts at the newest items so recently uploaded videos repair first, then checkpoints every
    /// successful metadata batch. `fetch_metadata` supports 150 links per call, so even a 35k
    /// library is a few hundred bounded requests rather than one request per asset.
    private func scheduleMediaTypeReconciliation(
        items: [PhotoItem],
        alreadyClassifiedNodeIDs: Set<String>
    ) {
        guard timelineStore != nil, mediaTypeReconciliationTask == nil else { return }
        let unknown = items.reversed().compactMap { item -> PhotoUID? in
            let nodeID = item.uid.nodeID
            guard !alreadyClassifiedNodeIDs.contains(nodeID) else { return nil }
            return item.uid
        }
        guard !unknown.isEmpty else { return }
        mediaTypeReconciliationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.reconcileMediaTypes(unknown)
        }
    }

    private func reconcileMediaTypes(_ unknown: [PhotoUID]) async {
        var changed = false
        defer {
            if changed, timelineStore?.publishMediaTypeEvidenceRevision() == false {
                DebugLog.log("timeline: could not publish reconciled media-type revision")
            }
            mediaTypeReconciliationTask = nil
        }
        do {
            let context = try await photosShareContext()
            var resolved = 0
            for batch in Self.metadataBatches(unknown) {
                try Task.checkCancellation()
                let links = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                    try await driveSession.fetchPhotoLinksMetadata(
                        shareID: context.shareID,
                        linkIDs: batch.map(\.nodeID)
                    )
                }
                let volumeID = batch[0].volumeID
                let evidence = Dictionary(
                    uniqueKeysWithValues: Self.mimeTypes(in: links).map { nodeID, mimeType in
                        (PhotoUID(volumeID: volumeID, nodeID: nodeID), mimeType)
                    }
                )
                let result = timelineStore?.recordMediaTypeEvidence(evidence, publishRevision: false)
                guard result?.succeeded != false else {
                    throw NSError(
                        domain: "EncryptedMemories.MediaTypeReconciliation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "media type checkpoint could not be saved"]
                    )
                }
                changed = changed || (result?.changedRows ?? 0) > 0
                resolved += evidence.count
            }
            DebugLog.log("timeline: media-type reconciliation resolved \(resolved)/\(unknown.count) links ✓")
        } catch is CancellationError {
            DebugLog.log("timeline: media-type reconciliation cancelled; persisted batches will resume")
        } catch {
            DebugLog.log("timeline: media-type reconciliation paused after a recoverable failure - \(error)")
        }
    }

    /// Splits links into the web client's `fetch_metadata` batch size, which every metadata read stays within.
    private static func metadataBatches<Element>(_ items: [Element]) -> [[Element]] {
        let size = UploadDedupePipeline.protonDuplicateBatchSize
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// The MIME types that a `fetch_metadata` batch names, by link ID.
    private static func mimeTypes(in links: [AlbumPhotoLinkBody]) -> [String: String] {
        Dictionary(
            links.compactMap { link -> (String, String)? in
                guard let linkID = link.linkID, let mimeType = link.mimeType else { return nil }
                return (linkID, mimeType)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The MIME type and the decrypted name of each link that a `fetch_metadata` batch names, by link ID. A name that
    /// does not decrypt stays unknown.
    private static func relatedFiles(
        in links: [AlbumPhotoLinkBody], rootKey: UnlockableKey?, crypto: DriveCrypto
    ) -> [String: BurstFrameVerdicts.RelatedFile] {
        Dictionary(
            links.compactMap { link -> (String, BurstFrameVerdicts.RelatedFile)? in
                guard let linkID = link.linkID else { return nil }
                var name: String?
                if let armored = link.name, let rootKey { name = try? crypto.decryptName(armored, parent: rootKey) }
                return (linkID, BurstFrameVerdicts.RelatedFile(mimeType: link.mimeType, name: name))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// A listing without the given photos: its sections, and the burst entries that the burst catalog reads. A kept
    /// burst entry also loses them as related photos, so the burst viewer does not show them as members.
    static func removing(
        _ uids: Set<PhotoUID>, from sections: [TimelineSection], burstEntries: [PhotosListEntry]?
    ) -> (sections: [TimelineSection], burstEntries: [PhotosListEntry]?) {
        let nodeIDs = Set(uids.map(\.nodeID))
        let entries = burstEntries?.compactMap { entry -> PhotosListEntry? in
            guard !nodeIDs.contains(entry.linkID) else { return nil }
            guard entry.relatedPhotos.contains(where: { nodeIDs.contains($0.linkID) }) else { return entry }
            return PhotosListEntry(
                linkID: entry.linkID, captureTime: entry.captureTime, tags: entry.tags,
                relatedPhotos: entry.relatedPhotos.filter { !nodeIDs.contains($0.linkID) })
        }
        return (TimelineContentProjection(sections: sections).removing(uids).sections, entries)
    }

    /// Tag and album listings lag behind a trash like the library listing. They leave out the photos trashed here,
    /// but only the library listing ends a wait.
    private func withoutPhotosTrashedHere(_ sections: [TimelineSection]) -> [TimelineSection] {
        guard recentlyDeleted.hasPhotosAwaitingLibrary else { return sections }
        let read = LibraryListingRead(listed: Set(sections.lazy.flatMap(\.items).map(\.uid)), readAt: Date())
        let lagging = recentlyDeleted.lagging(in: read, now: read.readAt)
        guard !lagging.isEmpty else { return sections }
        return Self.removing(lagging, from: sections, burstEntries: nil).sections
    }

    /// The files among `missing` that the photos listing must still show; see `TimelineRemoteVisibilityRequirement`.
    private func filesTheListingMustShow(_ missing: Set<String>) async throws -> Set<String> {
        guard let photosShareID else { return missing }
        let links = try await driveSession.fetchLinkVisibility(shareID: photosShareID, linkIDs: missing.sorted())
        let mainIDs = TimelineRemoteVisibilityRequirement.mainPhotoLinkIDs(of: links)
        let mainPhotos = try await driveSession.fetchLinkVisibility(shareID: photosShareID, linkIDs: mainIDs.sorted())
        return TimelineRemoteVisibilityRequirement.awaited(missing, links: links, mainPhotos: mainPhotos)
    }

    @discardableResult
    private func writeTimelineCache(_ sections: [TimelineSection], validationToken: String?) -> Bool {
        guard let store = timelineStore else { return false }
        let result = store.save(sections.flatMap(\.items), validationToken: validationToken)
        // Every load that saves chose its Live Photo motions with this rule; the next load trusts them.
        if result.succeeded, !store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule) {
            DebugLog.log("timeline: Live Photo motion mark not saved; the next load reads the types again")
        }
        if result.succeeded, result.sweptRows > 0 { timelineLostPhotos = true }
        if !result.succeeded {
            DebugLog.log("timeline: cache save failed - validation token not published")
        } else if result.skippedUnchanged {
            DebugLog.log("timeline: cache unchanged - save skipped (digest match)")
        } else {
            DebugLog.log(
                "timeline: cache saved gen=\(result.generation) upserts=\(result.upsertedRows) swept=\(result.sweptRows) ok=\(result.succeeded)"
            )
        }
        return result.succeeded
    }

    /// Evidence-only active links are completed uploads still converging into the Photos listing.
    /// Deleted links and Live Photo resources already represented by their main item may be pruned.
    private func activeNodeIDs(_ nodeIDs: Set<String>) async throws -> Set<String> {
        let context = try await photosShareContext()
        let ordered = nodeIDs.sorted()
        var active = Set<String>()
        let batchSize = UploadDedupePipeline.protonDuplicateBatchSize
        for start in stride(from: 0, to: ordered.count, by: batchSize) {
            let batch = Array(ordered[start..<min(start + batchSize, ordered.count)])
            let links = try await driveSession.fetchPhotoLinksMetadata(
                shareID: context.shareID,
                linkIDs: batch
            )
            active.formUnion(
                links.compactMap { link in
                    guard let linkID = link.linkID, link.state == nil || link.state == 1 else { return nil }
                    return linkID
                })
        }
        return active
    }

    // MARK: - LibraryStatsProvider

    /// Rows persisted in the local SQLite timeline store - surfaced as "metadata rows" in Settings.
    func metadataRowCount() async -> Int {
        (try? await withOpenSession { bridge in
            bridge.timelineStore?.count() ?? 0
        }) ?? 0
    }

    // MARK: - ThumbnailProvider

    func thumbnail(for uid: PhotoUID) async throws -> Data {
        try await withOpenSession { bridge in
            try await bridge.singleThumbnail(uid, type: .thumbnail)
        }
    }

    // MARK: - ThumbnailBatchLoader

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        do {
            return try await withOpenSession { bridge in
                await bridge.loadThumbnailsImpl(
                    for: uids,
                    priority: .nearViewportScrollAhead,
                    onLoaded: onLoaded
                )
            }
        } catch {
            return ThumbnailBatchLoadResult(batchError: "cancelled")
        }
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        do {
            return try await withOpenSession { bridge in
                await bridge.loadThumbnailsImpl(for: uids, priority: priority, onLoaded: onLoaded)
            }
        } catch {
            return ThumbnailBatchLoadResult(batchError: "cancelled")
        }
    }

    private func loadThumbnailsImpl(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let sdkUids = uids.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        let failures = BatchFailureBox()
        let isInteractive = priority == .visibleNow
        let priorityScope = await requestGovernor.beginPriorityScope(
            priority.requestPriority,
            promoting: [.api, .storageDownload],
            suspending: isInteractive ? [.storageUpload] : []
        )
        do {
            try await ProtonRequestContext.$priority.withValue(priority.requestPriority) {
                try await photosClient.downloadThumbnails(
                    photoUids: sdkUids,
                    type: .thumbnail,
                    cancellationToken: UUID(),
                    onThumbnailDownloaded: { result in
                        switch result {
                        case .success(let item?):
                            let uid = PhotoUID(volumeID: item.fileUid.volumeID, nodeID: item.fileUid.nodeID)
                            switch item.result {
                            case .success(let data):
                                onLoaded(uid, data)
                            case .failure(let error):
                                failures.recordItem(uid, reason: error.localizedDescription)
                            }
                        case .success(nil):
                            break
                        case .failure(let error):
                            failures.recordStream(error.localizedDescription)
                        }
                    }
                )
            }
        } catch {
            failures.recordStream((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        await requestGovernor.endPriorityScope(priorityScope)
        let result = failures.result
        if result != .delivered {
            let sample = result.itemErrors.first.map { "\($0.key.nodeID.prefix(8))…: \($0.value)" } ?? "-"
            DebugLog.log(
                "[ThumbBatch] n=\(uids.count) itemErrors=\(result.itemErrors.count) (\(sample)) batchError=\(result.batchError ?? "-")"
            )
        }
        return result
    }

    // MARK: - FullMediaProvider

    func preview(for uid: PhotoUID) async throws -> Data {
        try await withOpenSession { bridge in
            try await bridge.singleThumbnail(uid, type: .preview)
        }
    }

    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try await withOpenSession { bridge in
            try await bridge.originalDataImpl(for: uid, onProgress: onProgress)
        }
    }

    func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withOpenSession { bridge in
            try await bridge.streamOriginalBytesImpl(for: uid, onChunk: onChunk, onProgress: onProgress)
        }
    }

    private func streamOriginalBytesImpl(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            try await ProtonRequestContext.$priority.withValue(.immediate) {
                let source = try await fileSource()
                try await source.streamOriginalBytes(uid: uid, onChunk: onChunk, onProgress: onProgress)
            }
            await requestGovernor.endPriorityScope(priorityScope)
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
    }

    private func originalDataImpl(
        for uid: PhotoUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            let result = try await ProtonRequestContext.$priority.withValue(.immediate) {
                let source = try await fileSource()
                return try await source.originalData(uid: uid, onProgress: onProgress)
            }
            await requestGovernor.endPriorityScope(priorityScope)
            return result
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
    }

    func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withOpenSession { bridge in
            try await bridge.writeOriginalImpl(for: uid, to: destination, onProgress: onProgress)
        }
    }

    private func writeOriginalImpl(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) }

        let token = UUID()
        let sdkUID = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            let operation = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await photosClient.downloadOperation(
                    photoUid: sdkUID,
                    destinationUrl: partial,
                    cancellationToken: token,
                    progressCallback: { onProgress($0.fractionCompleted) }
                )
            }
            // Keep the export's partial file and open-session lease alive until native cancel
            // has settled, even when the download's terminal callback arrives first.
            let verificationIssue = try await SDKCancellableOperation.run(token: token) { _ in
                try await operation.awaitDownloadWithResilience(
                    operationalResilience: BasicOperationalResilience.default,
                    onRetriableErrorReceived: { error in
                        DebugLog.log("original file transfer retry: \(error.localizedDescription)")
                    }
                )
            } cancel: { _ in
                try? await operation.cancel()
            }
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            onProgress(1)
            if let verificationIssue {
                DebugLog.log(
                    "original file completed with verification warning: \(verificationIssue.localizedDescription)")
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            if Task.isCancelled { throw CancellationError() }
            throw Self.originalTransferError(from: error)
        }
        await requestGovernor.endPriorityScope(priorityScope)
    }

    /// Exports stop on a full device through `DeviceStorage.isOutOfSpace`, which cannot read the SDK's own
    /// error chain. Give that case the platform error and keep every other error unchanged.
    nonisolated static func originalTransferError(from error: any Error) -> any Error {
        guard let sdkError = error as? ProtonDriveSDKError else { return error }
        return originalTransferError(error, fileSystemCode: sdkError.underlyingFileSystemErrorCode)
    }

    nonisolated static func originalTransferError(
        _ error: any Error,
        fileSystemCode: ProtonDriveSDKError.FileSystemErrorCode?
    ) -> any Error {
        guard fileSystemCode == .outOfSpace else { return error }
        return CocoaError(.fileWriteOutOfSpace, userInfo: [NSUnderlyingErrorKey: error])
    }

    private func singleThumbnail(_ uid: PhotoUID, type: ThumbnailData.ThumbnailType) async throws -> Data {
        let sdkUid = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
        let box = DataBox()
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await photosClient.downloadThumbnails(
                    photoUids: [sdkUid],
                    type: type,
                    cancellationToken: UUID(),
                    onThumbnailDownloaded: { result in
                        if case .success(let item?) = result, case .success(let data) = item.result {
                            box.set(data)
                        }
                    }
                )
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
        await requestGovernor.endPriorityScope(priorityScope)
        guard let data = box.value else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    // MARK: - Photos root resolution

    private func resolvePhotosRoot() async throws -> SDKNodeUid {
        if let photosRoot { return photosRoot }
        let context = try await photosVolumeBootstrap.resolve()
        let root = SDKNodeUid(volumeID: context.volumeID, nodeID: context.rootLinkID)
        photosRoot = root
        photosShareID = context.shareID
        return root
    }

    /// The photos share context for the dedupe service - same discovery + cache as every other
    /// photos feature (`resolvePhotosRoot`).
    func photosShareContext() async throws -> PhotosShareContext {
        try await withOpenSession { bridge in
            try await bridge.photosShareContextImpl()
        }
    }

    private func photosShareContextImpl() async throws -> PhotosShareContext {
        let root = try await resolvePhotosRoot()
        guard let shareID = photosShareID else { throw DriveBridgeError.noPhotosShare }
        return PhotosShareContext(volumeID: root.volumeID, shareID: shareID, rootLinkID: root.nodeID)
    }

    /// Lazily builds (and caches) the streaming/metadata source once the photos share id is known.
    private func fileSource() async throws -> PhotoVideoStreamSource {
        _ = try await resolvePhotosRoot()  // ensures photosShareID is populated
        guard let shareID = photosShareID else { throw DriveBridgeError.noPhotosShare }
        if let streamSource { return streamSource }
        let source = PhotoVideoStreamSource(session: driveSession, crypto: crypto, shareID: shareID)
        streamSource = source
        return source
    }

    // MARK: - PhotoLibraryProvider

    nonisolated func makeAlbumCatalogBackend() -> SDKAlbumCatalogBackend {
        SDKAlbumCatalogBackend(
            client: photosClient,
            admission: shutdownGate,
            sharedAlbumSnapshotCache: sharedAlbumSnapshotCache
        )
    }

    /// Sets an album's cover to an already-uploaded photo (direct REST; SDK 0.29.1 has no album-write API).
    /// The photo's `nodeID` is its Drive link id.
    func setAlbumCover(albumID: String, photoUID: PhotoUID) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.setAlbumCover(
                volumeID: root.volumeID,
                albumLinkID: albumID,
                coverLinkID: photoUID.nodeID
            )
        }
    }

    func deleteAlbum(albumID: String) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.deleteAlbum(volumeID: root.volumeID, albumLinkID: albumID)
        }
    }

    func removePhotos(_ photoUIDs: [PhotoUID], fromAlbum albumID: String) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.removeFromAlbum(
                volumeID: root.volumeID,
                albumLinkID: albumID,
                linkIDs: photoUIDs.map(\.nodeID)
            )
        }
    }

    /// Refreshes the lightweight account snapshot used by Settings (email and Drive quota). The existing
    /// account-data request also updates the encrypted offline cache; it does not rebuild the signed-in client.
    func refreshAccountInfo() async throws {
        let recordedBefore = uploadedBytes
        try await withOpenSession { bridge in
            _ = try await bridge.driveSession.fetchAccountData()
        }
        // Uploads recorded during the request stay counted; the response may not contain them yet.
        uploadedBytesInQuota = max(uploadedBytesInQuota, recordedBefore)
    }

    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        try await withOpenSession { bridge in
            try await bridge.timelineImpl(filter: filter)
        }
    }

    /// Wired by the account composition. Every trash listing then authorizes what it shows.
    nonisolated func setIdentitiesOutsideInventoryObserver(
        _ observer: @escaping @Sendable (_ uids: [PhotoUID], _ sequence: UInt64) async -> Void
    ) {
        identitiesOutsideInventoryObserver.set(observer)
    }

    private func timelineImpl(filter: PhotoFilter) async throws -> [TimelineSection] {
        switch filter {
        case .all:
            return try await loadTimelineSnapshotImpl().sections
        case .tag(let tag):
            let root = try await resolvePhotosRoot()
            let entries = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: tag.rawValue)
            return try await withoutPhotosTrashedHere(filteredSections(entries, volumeID: root.volumeID))
        case .album(let id, _):
            let root = try await resolvePhotosRoot()
            let entries = try await driveSession.fetchAlbumPhotos(volumeID: root.volumeID, albumLinkID: id)
            return try await withoutPhotosTrashedHere(filteredSections(entries, volumeID: root.volumeID))
        case .sharedAlbum(let volumeID, let nodeID, _):
            // Shared albums live on another user's volume, so the owned-volume HTTP album route cannot list
            // them. The SDK catalog adapter is the only content source; it proves identity and capture time only.
            let items = try await makeAlbumCatalogBackend()
                .librarySourceItems(for: AlbumNodeIdentifier(volumeID: volumeID, nodeID: nodeID))
                .map(\.item)
                .sorted(by: TimelineOrder.areInIncreasingOrder)
            return [
                TimelineSection(
                    id: "shared-album", date: items.first?.captureTime ?? .distantPast, title: "", items: items)
            ]
        case .trash:
            let photos: [PhotoItem]
            do {
                photos = try await listTrash()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Offline or unreachable, Recently Deleted shows the last listing it received; the thumbnail crawl
                // already put its thumbnails on disk. Every other failure, such as a lost session, still shows.
                guard (error as NSError).domain == NSURLErrorDomain, let listing = recentlyDeleted.listing else {
                    throw error
                }
                DebugLog.log("trash: listing unreachable, showing the stored listing (\(listing.count) items)")
                PhotoDiagnostics.shared.increment("recentlyDeleted.storedListingShown")
                photos = listing
            }
            return [
                TimelineSection(id: "trash", date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)
            ]
        case .map, .duplicates:
            return []  // these routes render the map or the duplicate groups, not a timeline
        }
    }

    // MARK: - FavoritesProvider

    func favoriteUIDs() async throws -> Set<PhotoUID> {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            let entries = try await bridge.driveSession.fetchPhotosList(
                volumeID: root.volumeID,
                tag: LibraryPhotoTag.favorites.rawValue
            )
            return Set(entries.map { PhotoUID(volumeID: root.volumeID, nodeID: $0.linkID) })
        }
    }

    func setFavorites(_ uids: [PhotoUID], _ favorite: Bool) async throws {
        try await withOpenSession { bridge in
            try await SDKFavoriteWriter(client: bridge.photosClient).setFavorites(uids, favorite: favorite)
        }
    }

    // MARK: - PhotoLibrarySaving

    func saveToLibrary(_ uids: [PhotoUID]) async throws -> PhotoLibrarySaveResult {
        try await withOpenSession { bridge in
            try await SDKPhotoLibrarySaver(client: bridge.photosClient).save(uids)
        }
    }

    // MARK: - TrashProvider

    /// The person moves photos to the trash.
    func trash(_ uids: [PhotoUID]) async throws {
        try await moveToTrash(uids)
    }

    /// The backup moves the photos that an edit replaced to the trash. This is no deletion by the person.
    func trashReplaced(_ uids: [PhotoUID]) async throws {
        try await moveToTrash(uids)
    }

    private func moveToTrash(_ uids: [PhotoUID]) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.trash(volumeID: root.volumeID, linkIDs: uids.map(\.nodeID))
            // The next library refresh drops these photos; they keep their thumbnails in Recently Deleted. They
            // join the stored listing at once, so a relaunch before the next listing keeps them too.
            let known = (bridge.timelineStore?.items(for: uids) ?? []).map {
                RecentlyDeletedItem.make(
                    volumeID: $0.uid.volumeID, nodeID: $0.uid.nodeID, captureTime: $0.captureTime, isVideo: $0.isVideo)
            }
            bridge.recentlyDeleted.trashed(uids, items: known)
            bridge.recentlyDeletedStore.save(bridge.recentlyDeleted.persisted)
            // The launch shows the stored timeline before the next listing; it must not show these photos.
            bridge.timelineStore?.remove(uids)
            await bridge.reportRecentlyDeleted()
            // Debug-gated end-to-end verification: the moved links must actually surface in the volume trash
            // listing (this is the seam that silently broke before - trash "succeeded" but Recently Deleted
            // stayed empty). Costs one extra listing round-trip, only when the debug log is on.
            if DebugLog.isEnabled {
                let trashed = Set(
                    (try? await bridge.driveSession.listTrash(volumeID: root.volumeID))?.compactMap(\.linkID) ?? []
                )
                let missing = uids.map(\.nodeID).filter { !trashed.contains($0) }
                DebugLog.log(
                    "trash-verify: \(uids.count - missing.count)/\(uids.count) moved links visible in trash listing"
                        + (missing.isEmpty
                            ? "" : " MISSING=\(missing.map { $0.prefix(8) + "…" }.joined(separator: ","))"))
            }
        }
    }

    func restore(_ uids: [PhotoUID]) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.restore(volumeID: root.volumeID, linkIDs: uids.map(\.nodeID))
            // A listing can drop these photos before the library lists them again; their thumbnails stay.
            bridge.recentlyDeleted.restored(uids)
            bridge.recentlyDeletedStore.save(bridge.recentlyDeleted.persisted)
            await bridge.reportRecentlyDeleted()
        }
    }

    func emptyTrash() async throws {
        try await withOpenSession { bridge in
            _ = try await bridge.resolvePhotosRoot()
            try await SDKCancellableOperation.run { [photosClient = bridge.photosClient] cancellationToken in
                try await photosClient.emptyTrash(cancellationToken: cancellationToken)
            } cancel: { [photosClient = bridge.photosClient] cancellationToken in
                try? await photosClient.cancelEmptyTrash(cancellationToken: cancellationToken)
            }
            bridge.recentlyDeleted.emptied()
            bridge.recentlyDeletedStore.save(bridge.recentlyDeleted.persisted)
            await bridge.reportRecentlyDeleted()
        }
    }

    // MARK: - Recently Deleted

    /// The photos of the stored listing, newest first, with the report sequence. The account composition registers
    /// them before the first cache sweep, so their thumbnails survive a launch before the route or a listing runs.
    func recentlyDeletedReport() -> (uids: [PhotoUID], sequence: UInt64) {
        recentlyDeletedReportSequence &+= 1
        return (recentlyDeleted.ordered, recentlyDeletedReportSequence)
    }

    /// Lists the volume trash, stores the listing, and registers its photos for their thumbnails.
    private func listTrash() async throws -> [PhotoItem] {
        guard !isShutDown else { throw CancellationError() }
        let ticket = recentlyDeleted.beginListing()
        let root = try await resolvePhotosRoot()
        let links = try await driveSession.listTrash(volumeID: root.volumeID)
            .filter { $0.type != 1 && $0.type != 3 }  // drop folders + albums; keep files/unknown
            .filter { $0.mainPhotoLinkID == nil }  // hide Live-Photo paired videos, like the timeline
        let photos =
            links
            .compactMap { l -> PhotoItem? in
                guard let id = l.linkID else { return nil }
                return RecentlyDeletedItem.make(
                    volumeID: root.volumeID,
                    nodeID: id,
                    captureTime: Date(timeIntervalSince1970: l.captureTime),
                    isVideo: l.mimeType?.hasPrefix("video/") == true)
            }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
        guard !isShutDown else { throw CancellationError() }
        // A trash, restore, or Empty Trash request finished meanwhile, or a listing that started later was already
        // applied. Both are newer than this listing, so the route shows that state instead.
        let stored = recentlyDeleted.persisted
        switch recentlyDeleted.received(photos, ticket: ticket) {
        case .applied:
            break
        case .overtakenByChange:
            // Photos that left the library meanwhile may still lack a listing. A background listing follows; when
            // this is the background listing itself, the next library refresh starts it.
            scheduleTrashListing()
            return recentlyDeleted.listing ?? photos
        case .superseded:
            return recentlyDeleted.listing ?? photos
        }
        if recentlyDeleted.persisted != stored {
            DebugLog.log("trash: listing has \(photos.count) items")
            recentlyDeletedStore.save(recentlyDeleted.persisted)
        }
        // A trashed photo left every inventory, so only this listing proves that the user may read it.
        await reportRecentlyDeleted()
        // Includes photos trashed here that the server does not list yet.
        return recentlyDeleted.listing ?? photos
    }

    private func reportRecentlyDeleted() async {
        let report = recentlyDeletedReport()
        await identitiesOutsideInventoryObserver.report(report.uids, sequence: report.sequence)
    }

    /// Lists the trash at maintenance priority once per session, so photos trashed on another device before this
    /// launch get their thumbnails (the crawl fetches them last), and again after a listing failed or went stale.
    /// A library refresh that lost photos lists the trash itself.
    private func scheduleTrashListing() {
        guard !isShutDown, trashListingTask == nil, recentlyDeleted.needsListing else { return }
        trashListingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.listTrashInBackground()
        }
    }

    private func listTrashInBackground() async {
        defer { trashListingTask = nil }
        do {
            _ = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await listTrash()
            }
        } catch {
            DebugLog.log("trash: background listing failed - \(error)")
        }
    }

    /// Sections of a tag filter or an album. A failed type read leaves a Live Photo with several related files without
    /// its motion; the next open reads again.
    private func filteredSections(_ entries: [PhotosListEntry], volumeID: String) async throws -> [TimelineSection] {
        let evidence = timelineStore?.mediaTypeEvidence(volumeID: volumeID) ?? [:]
        let motions = try await livePhotoMotions(
            of: Self.livePhotos(in: entries), volumeID: volumeID, evidence: evidence)
        return Self.group(entries, volumeID: volumeID, mediaTypeOverrides: evidence, motions: motions)
    }

    /// The related files of each Live Photo in `entries` in listing order, by link ID.
    private static func livePhotos(in entries: [PhotosListEntry]) -> [String: [String]] {
        Dictionary(
            entries.lazy.filter(\.isLivePhoto).map { ($0.linkID, $0.relatedLinkIDs) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The motion of each of these Live Photos (`LivePhotoMotionLinks.motions`). A motion that this rule stored with the
    /// timeline holds without a read; the related files that still need a type are read in metadata batches, a few at a
    /// time. A failed read leaves those motions unknown without holding back the timeline cache: an unknown motion saves
    /// no related video, so the next refresh reads exactly those photos again.
    private func livePhotoMotions(
        of livePhotos: [String: [String]], volumeID: String, evidence: [String: String]
    ) async throws -> [String: LivePhotoMotion] {
        let stored = LivePhotoMotionLinks.storedMotions(of: livePhotos, volumeID: volumeID, in: timelineStore)
        let answer = try await livePhotoMotionLinks.motions(of: livePhotos, stored: stored, evidence: evidence) {
            [driveSession, photosShareID] linkIDs in
            guard let shareID = photosShareID else { throw DriveBridgeError.noPhotosShare }
            let start = Date()
            let batches = try await Self.concurrentMetadataBatches(linkIDs) { batch in
                Self.mimeTypes(in: try await driveSession.fetchPhotoLinksMetadata(shareID: shareID, linkIDs: batch))
            }
            DebugLog.log(
                "timeline: read the type of \(linkIDs.count) Live Photo related files in \(batches.count) requests, "
                    + "\(Int(Date().timeIntervalSince(start) * 1000)) ms; \(stored.count) stored motions held")
            return batches.reduce(into: [:]) { types, batch in types.merge(batch) { first, _ in first } }
        }
        livePhotoMotionLinks.record(answer.read)
        return answer.motions
    }

    /// Reads `linkIDs` in metadata batches, at most `ProtonUploadDedupeService.remoteMetadataRequestConcurrency` at a
    /// time. The answers keep the batch order. The first failure cancels the other batches and ends the read.
    static func concurrentMetadataBatches<Answer: Sendable>(
        _ linkIDs: [String], read: @escaping @Sendable (_ batch: [String]) async throws -> Answer
    ) async throws -> [Answer] {
        let batches = metadataBatches(linkIDs)
        return try await withThrowingTaskGroup(of: (Int, Answer).self) { group in
            var next = 0
            func submitNext() {
                guard next < batches.count else { return }
                let index = next
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await read(batches[index]))
                }
            }
            for _ in 0..<min(ProtonUploadDedupeService.remoteMetadataRequestConcurrency, batches.count) { submitNext() }
            var answers = [Answer?](repeating: nil, count: batches.count)
            while let (index, answer) = try await group.next() {
                answers[index] = answer
                submitNext()
            }
            return answers.compactMap { $0 }
        }
    }

    /// Builds timeline sections from direct-listing entries (tag filters + album contents). `motions` holds the motion
    /// of each Live Photo with several related files.
    static func group(
        _ entries: [PhotosListEntry],
        volumeID: String,
        mediaTypeOverrides: [String: String] = [:],
        motions: [String: LivePhotoMotion] = [:],
        sectionID: String = "filtered"
    ) -> [TimelineSection] {
        let burstMemberIDs = burstMemberLookup(from: entries)
        let photos =
            entries
            .map { e -> PhotoItem in
                photoItem(
                    from: e,
                    volumeID: volumeID,
                    mediaTypeOverride: mediaTypeOverrides[e.linkID],
                    motion: motions[e.linkID],
                    burstMemberIDs: burstMemberIDs[e.linkID] ?? []
                )
            }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
        return [
            TimelineSection(id: sectionID, date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)
        ]
    }

    // MARK: - PhotoMetadataProvider

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        try await withOpenSession { bridge in
            try await bridge.metadataImpl(for: uid)
        }
    }

    private func metadataImpl(for uid: PhotoUID) async throws -> PhotoMetadata {
        let metadata = try await SDKPhotoMetadataReader.metadata(for: uid, client: photosClient)
        if let mimeType = metadata.mimeType {
            let result = timelineStore?.recordMediaTypeEvidence([uid: mimeType])
            if result?.succeeded == false {
                DebugLog.log("timeline: could not persist media type resolved by viewer")
            }
        }
        if let duration = metadata.durationSeconds {
            let result = timelineStore?.updateDurations([uid: duration])
            if result?.succeeded == false {
                DebugLog.log("timeline: could not persist video duration resolved from metadata")
            }
        }
        return metadata
    }

    // MARK: - BurstGroupProvider

    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {
        try await withOpenSession { bridge in
            try await bridge.burstGroupImpl(containing: uid)
        }
    }

    private func burstGroupImpl(containing uid: PhotoUID) async throws -> [PhotoItem] {
        let root = try await resolvePhotosRoot()
        let burstEntries: [PhotosListEntry]
        let lookup: [String: [String]]
        if let cached = burstCatalogEntries {
            // The cached tagged listing is complete. A missing UID is a confirmed non-member, not a reason to
            // enumerate the same potentially large bursts listing again.
            burstEntries = cached
            lookup = burstCatalogLookup
        } else {
            let fetched = try await driveSession.fetchPhotosList(
                volumeID: root.volumeID, tag: LibraryPhotoTag.bursts.rawValue)
            let fetchedLookup = Self.burstMemberLookup(from: fetched)
            burstCatalogEntries = fetched
            burstCatalogLookup = fetchedLookup
            burstEntries = fetched
            lookup = fetchedLookup
        }
        guard let relatedIDs = lookup[uid.nodeID], relatedIDs.count > 1 else { return [] }

        let entriesByID = Dictionary(burstEntries.map { ($0.linkID, $0) }, uniquingKeysWith: { first, _ in first })
        // Related files outside the bursts listing can be frames of another Proton client or the adjustment data of
        // an edit. One metadata read per open tells them apart by name and type; a reopen reuses the verdicts.
        let keySource = try? await fileSource()
        let checked = await BurstFrameVerdicts.frames(
            of: relatedIDs,
            listed: Set(entriesByID.keys),
            verdicts: burstFrameVerdicts
        ) { [driveSession, crypto, keySource, shareID = photosShareID, rootLinkID = root.nodeID] linkIDs in
            guard let shareID, let keySource else { throw DriveBridgeError.noPhotosShare }
            var links: [AlbumPhotoLinkBody] = []
            for batch in Self.metadataBatches(linkIDs) {
                links += try await ProtonRequestContext.$priority.withValue(.userInitiated) {
                    try await driveSession.fetchPhotoLinksMetadata(shareID: shareID, linkIDs: batch)
                }
            }
            // Photos are children of the photos root, whose key decrypts their names. The stream source caches it.
            var rootKey: UnlockableKey?
            if links.contains(where: { $0.name != nil }) {
                rootKey = try await ProtonRequestContext.$priority.withValue(.userInitiated) {
                    try await keySource.nodeKey(ofLinkID: rootLinkID)
                }
            }
            return Self.relatedFiles(in: links, rootKey: rootKey, crypto: crypto)
        }
        burstFrameVerdicts.merge(checked.verdicts)
        let memberIDs = checked.frames
        guard memberIDs.count > 1 else { return [] }

        let anchorEntry =
            entriesByID[uid.nodeID]
            ?? burstEntries.first { entry in
                memberIDs.contains(entry.linkID)
            }
        let anchorTime = anchorEntry.map { Date(timeIntervalSince1970: $0.captureTime) } ?? .distantPast

        return memberIDs.enumerated().map { offset, id in
            if let entry = entriesByID[id] {
                return Self.photoItem(from: entry, volumeID: root.volumeID, burstMemberIDs: memberIDs)
            }
            return Self.syntheticBurstMember(
                id: id,
                volumeID: root.volumeID,
                memberIDs: memberIDs,
                anchorTime: anchorTime,
                offset: offset
            )
        }
    }

    // MARK: - VideoStreamProvider

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        try await withOpenSession { bridge in
            try await bridge.makeStreamingAssetImpl(for: uid)
        }
    }

    private func makeStreamingAssetImpl(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        let source: PhotoVideoStreamSource
        do {
            source = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await fileSource()
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }

        // Throws `.notAVideo` cheaply for images, so the viewer falls back to its image path.
        let prepared: PreparedVideo
        do {
            prepared = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await source.prepare(uid: uid)
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
        let loader = ProtonVideoResourceLoader(
            prepared: prepared,
            source: source,
            crypto: crypto,
            admission: shutdownGate
        )
        // Unique per-item URL so AVFoundation never reuses a cached asset/loader across videos.
        let host = uid.nodeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "stream"
        let asset = AVURLAsset(url: URL(string: "protonvideo://\(host)")!)
        let queue = DispatchQueue(label: "me.proton.photos.video-loader")
        asset.resourceLoader.setDelegate(loader, queue: queue)
        // Fetch and decrypt the first blocks while AVFoundation still inspects the asset, so its own
        // start-of-playback decision can already count on served bytes.
        loader.primePlaybackStart()
        await requestGovernor.endPriorityScope(priorityScope)
        return StreamingVideoAsset(asset: asset, retaining: loader)
    }

    func prefetchEncrypted(for uid: PhotoUID) async throws {
        try await withOpenSession { bridge in
            let priorityScope = await bridge.requestGovernor.beginPriorityScope(
                .immediate,
                promoting: [.api, .storageDownload],
                suspending: [.storageUpload]
            )
            do {
                try await ProtonRequestContext.$priority.withValue(.immediate) {
                    let source = try await bridge.fileSource()
                    try await source.prefetchEncrypted(uid: uid)
                }
                await bridge.requestGovernor.endPriorityScope(priorityScope)
            } catch {
                await bridge.requestGovernor.endPriorityScope(priorityScope)
                throw error
            }
        }
    }

    // MARK: - Mapping

    /// Builds timeline sections from the SDK timeline. `livePhotoMotions` holds the motion of each Live Photo.
    static func group(
        _ items: [PhotoTimelineItem], videoNodeIDs: Set<String> = [],
        mediaTypeOverrides: [String: String] = [:],
        livePhotoMotions: [String: LivePhotoMotion] = [:],
        burstMemberIDs: [String: [String]] = [:]
    ) -> [TimelineSection] {
        let photos =
            items
            .map { item -> PhotoItem in
                let nodeID = item.nodeUid.nodeID
                let mediaType =
                    mediaTypeOverrides[nodeID]
                    ?? (videoNodeIDs.contains(nodeID) ? "video/quicktime" : "image/jpeg")
                let isVideo = mediaType.hasPrefix("video/")
                let motion = livePhotoMotions[nodeID] ?? .noVideo
                let relatedVideo = motion.linkID  // a live photo's paired video link, if any
                let burstMembers = burstMemberIDs[nodeID] ?? []
                var tags: Set<LibraryPhotoTag> = []
                if isVideo { tags.insert(.videos) }
                if relatedVideo != nil { tags.insert(.motionPhotos) }
                if burstMembers.count > 1 { tags.insert(.bursts) }
                return PhotoItem(
                    uid: PhotoUID(volumeID: item.nodeUid.volumeID, nodeID: nodeID),
                    captureTime: Date(timeIntervalSince1970: item.captureTime),
                    mediaType: mediaType,
                    isLivePhoto: motion.showsLiveControl,
                    relatedVideoID: relatedVideo,
                    tags: tags,
                    burstMemberIDs: burstMembers)
            }
            // Ascending order places the oldest item at the top and the newest at the bottom.
            // The grid opens scrolled to the bottom so the newest photos are shown first. The
            // comparator is the canonical (t, vol, node) timeline order, matching the DB index, so
            // equal-second captures keep a stable position across refreshes and relaunches.
            .sorted(by: TimelineOrder.areInIncreasingOrder)

        // one continuous section - no per-day/month breaks. Apple's "All Photos" is a single
        // uninterrupted justified run, which also keeps pinch-zoom smooth (no divider lines to
        // disturb the re-justify) and makes thumbnail sizing consistent across the whole library.
        return [TimelineSection(id: "all", date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)]
    }

    private static func tags(from rawValues: [Int]) -> Set<LibraryPhotoTag> {
        Set(rawValues.compactMap(LibraryPhotoTag.init(rawValue:)))
    }

    private static func photoItem(
        from entry: PhotosListEntry,
        volumeID: String,
        mediaTypeOverride: String? = nil,
        motion: LivePhotoMotion? = nil,
        burstMemberIDs: [String] = []
    ) -> PhotoItem {
        let mediaType =
            mediaTypeOverride
            ?? (entry.tags.contains(LibraryPhotoTag.videos.rawValue) ? "video/quicktime" : "image/jpeg")
        let isVideo = mediaType.hasPrefix("video/")
        var tags = Self.tags(from: entry.tags)
        tags.remove(.videos)
        if isVideo { tags.insert(.videos) }
        if burstMemberIDs.count > 1 { tags.insert(.bursts) }
        let motion: LivePhotoMotion =
            entry.isLivePhoto
            ? motion ?? LivePhotoMotionLinks.motion(among: entry.relatedLinkIDs, mimeTypes: [:]) : .noVideo
        return PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: entry.linkID),
            captureTime: Date(timeIntervalSince1970: entry.captureTime),
            mediaType: mediaType,
            isLivePhoto: motion.showsLiveControl,
            relatedVideoID: motion.linkID,
            tags: tags,
            burstMemberIDs: burstMemberIDs
        )
    }

    private static func syntheticBurstMember(
        id: String,
        volumeID: String,
        memberIDs: [String],
        anchorTime: Date,
        offset: Int
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: id),
            captureTime: anchorTime.addingTimeInterval(Double(offset) * 0.001),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: memberIDs
        )
    }

    private static func burstMemberLookup(from entries: [PhotosListEntry]) -> [String: [String]] {
        let candidates =
            entries
            .filter { $0.tags.contains(LibraryPhotoTag.bursts.rawValue) }
            .map {
                BurstGroupCandidate(
                    id: $0.linkID,
                    relatedIDs: $0.relatedPhotos.map(\.linkID),
                    captureTime: Date(timeIntervalSince1970: $0.captureTime)
                )
            }
        return BurstGroupResolver.memberLookup(candidates: candidates)
    }
}

private extension ThumbnailPriority {
    var requestPriority: ProtonRequestPriority {
        switch self {
        case .visibleNow: .immediate
        case .zoomAnchorAndFocusRow: .userInitiated
        case .likelyZoomOutTargetCoverage, .nearViewportScrollAhead: .foregroundPrefetch
        case .idleLibraryCrawl: .maintenance
        }
    }
}

// MARK: - PhotoDimensionRecording (learned w/h into the library metadata DB)

extension DriveSDKBridge: PhotoDimensionRecording {
    /// Batched by `PhotoDimensionCoalescer`; the store fills only rows without dimensions
    /// (first-seen-wins), so repeated decodes and future true-dimension writers can coexist.
    func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async {
        _ = try? await withOpenSession { bridge in
            bridge.timelineStore?.updateDimensions(batch)
        }
    }
}

// MARK: - PhotoUploading (UploadFeature seam)

/// Library upload via the SDK's `EncryptedMemoriesClient`. The SDK resolves the photos root itself, encrypts
/// + streams blocks (through `SDKHttpClient.requestUploadToStorage`), and returns the new node id. The
/// queue/state-machine lives in the pure `UploadManager`; this is just the transport.
extension DriveSDKBridge: PhotoUploading {
    nonisolated var capabilities: UploadBackendCapabilities {
        // The SDK exposes operation-level pause/resume, but we drive uploads through the `uploadPhoto`
        // convenience (no held operation), so in-flight pause isn't wired: queued items pause at the
        // queue level; cancelled/failed items retry from the start (honestly, not byte-resumed).
        .sdkUploader
    }

    /// Compares the file with the account's remaining Drive storage: the last account refresh minus what this session
    /// uploaded since. When it does not fit, the account data is refreshed first, at most once a minute, because the
    /// person may have freed space or upgraded; checks during a refresh wait for it, and a cancelled check stops
    /// waiting at once. Without a known quota the upload proceeds; Proton then decides.
    nonisolated func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws {
        guard bytes > 0, let available = await remainingDriveBytes(), bytes > available else { return }
        await refreshQuotaIfDue()
        guard let refreshed = await remainingDriveBytes(), bytes > refreshed else { return }
        DebugLog.log("[Upload] storage full file=\(filename) needs=\(bytes) left=\(refreshed)")
        throw UploadError.accountStorageFull(filename, requiredBytes: bytes, availableBytes: max(0, refreshed))
    }

    private func remainingDriveBytes() async -> Int64? {
        let quota = await MainActor.run { () -> (used: Int64, max: Int64)? in
            guard let used = AccountInfo.shared.driveUsedSpaceBytes,
                let maximum = AccountInfo.shared.driveMaxSpaceBytes, maximum > 0
            else { return nil }
            return (used, maximum)
        }
        guard let quota else { return nil }
        return quota.max - quota.used - (uploadedBytes - uploadedBytesInQuota)
    }

    /// Starts one account refresh when none ran in the last minute, then waits for the running refresh. The refresh
    /// belongs to no single check, so cancelling one check neither cancels it nor keeps that check waiting.
    private func refreshQuotaIfDue() async {
        if quotaRefresh == nil {
            let now = ContinuousClock.now
            if let lastQuotaRefreshAt, lastQuotaRefreshAt.duration(to: now) < .seconds(60) { return }
            lastQuotaRefreshAt = now
            quotaRefresh = Task {
                _ = try? await self.refreshAccountInfo()
                self.finishQuotaRefresh()
            }
        }
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if quotaRefresh == nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    quotaRefreshWaiters[waiter] = continuation
                }
            }
        } onCancel: {
            Task { await self.stopWaitingForQuotaRefresh(waiter) }
        }
    }

    private func finishQuotaRefresh() {
        quotaRefresh = nil
        let waiters = quotaRefreshWaiters.values
        quotaRefreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func stopWaitingForQuotaRefresh(_ waiter: UUID) {
        quotaRefreshWaiters.removeValue(forKey: waiter)?.resume()
    }

    /// The universal dedupe pipeline for this account: the SQLite identity manifest (per-account
    /// directory, purged on sign-out) + the Proton-keyed duplicate service. Built once at facade
    /// composition. If the manifest cannot open, return a fail-closed resolver: uploading without
    /// duplicate protection would risk library duplicates.
    nonisolated func makeUploadIdentityResolver() -> UploadIdentityResolverComposition {
        guard let store = UploadIdentityManifestStore(url: uploadManifestURL, policy: uploadManifestPolicy) else {
            DebugLog.log("[Dedupe] manifest store unavailable - uploads disabled")
            return UploadIdentityResolverComposition(
                resolver: ShutdownGatedUploadIdentityResolver(
                    base: DedupeUnavailableIdentityResolver(),
                    admission: shutdownGate
                ),
                duplicateChecker: nil,
                identityStore: nil,
                contentIndex: nil,
                replacementJournal: nil,
                close: {}
            )
        }
        // Nil when the journal file cannot be read: edits then keep their earlier uploads.
        let replacementJournal = EditReplacementJournalFileStore.shared(
            accountDataDirectory: uploadManifestURL.deletingLastPathComponent())
        let lineageStore = UploadRemoteLineageIndexStore(
            url: uploadManifestURL.deletingLastPathComponent()
                .appendingPathComponent(UploadRemoteLineageIndexStore.databaseFileName),
            policy: uploadManifestPolicy)
        if lineageStore == nil {
            DebugLog.log("[Dedupe] lineage index unavailable; reads remain incomplete")
        }
        let service = ProtonUploadDedupeService(
            session: driveSession,
            crypto: crypto,
            photosClient: photosClient,
            contentIndexStore: store,
            lineageIndexStore: lineageStore
        ) { [self] in
            try await photosShareContext()
        }
        let pipeline = UploadDedupePipeline(
            store: store,
            checker: service,
            currentClientUID: uploadClientUID,
            replacementJournal: replacementJournal
        )
        return UploadIdentityResolverComposition(
            resolver: ShutdownGatedUploadIdentityResolver(base: pipeline, admission: shutdownGate),
            duplicateChecker: service,
            identityStore: store,
            contentIndex: store,
            replacementJournal: replacementJournal,
            close: {
                lineageStore?.close()
                store.close()
            }
        )
    }

    /// The album WRITE service (create + add-photos crypto/REST). Built once at facade
    /// composition; shares the bridge's session, crypto, and photos-share discovery.
    nonisolated func makeAlbumWriteService() -> ProtonAlbumWriteService {
        ProtonAlbumWriteService(
            session: driveSession,
            crypto: crypto,
            admission: shutdownGate
        ) { [self] in
            try await photosShareContext()
        }
    }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        try await withOpenSession { bridge in
            try await bridge.uploadImpl(request, onProgress: onProgress)
        }
    }

    private func uploadImpl(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        guard !isShutDown else { throw CancellationError() }
        try Task.checkCancellation()
        onProgress(UploadProgress(phase: .preparing))
        let isVideo = request.mediaType.hasPrefix("video/")
        let thumbnails = await UploadMediaProcessor.thumbnails(for: request.fileURL, isVideo: isVideo)
        try Task.checkCancellation()
        onProgress(UploadProgress(phase: .uploading, fraction: 0))
        do {
            // Secondary resources (a Live Photo's paired video) reference their primary. Core may
            // only know the primary's LINK id (from a duplicate-check row, which carries no
            // volume); every photo lives in the single photos volume, so an empty volumeID
            // resolves to the photos root's volume here at the transport boundary.
            var mainPhotoUid: SDKNodeUid?
            if let main = request.mainPhotoUID {
                let volumeID = main.volumeID.isEmpty ? try await resolvePhotosRoot().volumeID : main.volumeID
                try Task.checkCancellation()
                mainPhotoUid = SDKNodeUid(volumeID: volumeID, nodeID: main.nodeID)
            }
            try Task.checkCancellation()
            let operation = try await photosClient.uploadOperation(
                name: request.name,
                fileURL: request.fileURL,
                fileSize: request.fileSize,
                modificationDate: request.modificationDate,
                captureTime: request.captureTime,
                mainPhotoUid: mainPhotoUid,
                mediaType: request.mediaType,
                thumbnails: thumbnails,
                tags: Self.normalizedUploadTags(
                    requested: request.tags,
                    mediaType: request.mediaType,
                    isRelatedResource: mainPhotoUid != nil
                ),
                additionalMetadata: request.additionalMetadata.map {
                    AdditionalMetadata(name: $0.name, utf8JsonValue: $0.utf8JsonValue)
                },
                overrideExistingDraft: request.overrideExistingDraft,
                // From the dedupe pipeline's hashing phase - the SDK verifies the streamed bytes
                // against this digest server-side.
                expectedSHA1: request.expectedSHA1,
                cancellationToken: request.cancellationToken,
                progressCallback: { p in
                    onProgress(UploadProgress(phase: .uploading, fraction: p.fractionCompleted))
                }
            )
            let ids: UploadedFileIdentifiers
            do {
                try Task.checkCancellation()
                guard !operation.isCancellationRequested else { throw CancellationError() }
                try operation.claimStart()
                try Task.checkCancellation()
                ids = try await photosClient.startUpload(
                    operation: operation,
                    onRetriableErrorReceived: { _ in }
                )
            } catch {
                // The SDK deliberately keeps a cancelled operation's server draft so callers that
                // retain the operation can resume it. We do not support relaunch-resume, therefore
                // losing this local operation without disposal would strand the name indefinitely.
                if error is CancellationError || Self.isSDKCancellation(error) {
                    do {
                        try await operation.cleanUpTemporaryState()
                    } catch let cleanupError {
                        // Keep cancellation semantics for the queue. A later same-client preflight
                        // can still replace the draft if Proton could not dispose it right now.
                        DebugLog.log("[Upload] cancellation cleanup failed file=\(request.name) err=\(cleanupError)")
                    }
                }
                await operation.releaseResources()
                throw error
            }
            await operation.releaseResources()
            uploadedBytes += max(0, request.fileSize)
            DebugLog.log("[Upload] completed node=\(ids.nodeUid.nodeID.prefix(8))… file=\(request.name)")
            let uid = PhotoUID(volumeID: ids.nodeUid.volumeID, nodeID: ids.nodeUid.nodeID)
            if mainPhotoUid == nil {
                pendingUploadedNodeIDs.insert(uid.nodeID)
            }
            _ = timelineStore?.recordMediaTypeEvidence(
                [uid: request.mediaType],
                publishRevision: false
            )
            return uid
        } catch {
            DebugLog.log("[Upload] FAILED file=\(request.name) err=\(error)")
            if error is CancellationError || Self.isSDKCancellation(error) {
                throw CancellationError()
            }
            throw Self.uploadError(from: error, filename: request.name)
        }
    }

    /// Standalone videos must carry Proton's tag 2 at creation; relying on asynchronous server
    /// classification produced valid movie bytes that every tag-driven timeline exposed as still
    /// images. A Live Photo's related motion resource is deliberately untagged so it cannot surface
    /// as a second standalone grid item.
    nonisolated static func normalizedUploadTags(
        requested: [Int],
        mediaType: String,
        isRelatedResource: Bool
    ) -> [Int] {
        var tags = Set(requested)
        if mediaType.lowercased().hasPrefix("video/") && !isRelatedResource {
            tags.insert(LibraryPhotoTag.videos.rawValue)
        } else {
            tags.remove(LibraryPhotoTag.videos.rawValue)
        }
        return tags.sorted()
    }

    /// Preserve the SDK's typed failure domain at the Core boundary. URL/socket failures retry as
    /// network problems; HTTP 408/429/5xx retry as temporary service failures; other API responses
    /// retain Proton's concrete message and follow the ordinary finite item retry policy.
    nonisolated static func uploadError(from error: Error, filename: String) -> any Error {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return UploadCore.UploadError.transport(code: nsError.code, message: message)
        }
        guard let sdkError = error as? ProtonDriveSDKError else {
            return UploadCore.UploadError.backend(message)
        }
        if let fileSystemError = sdkError.underlyingFileSystemErrorCode,
            let mapped = uploadFileSystemError(fileSystemError, filename: filename)
        {
            return mapped
        }
        if sdkError.underlyingSocketNetworkError != nil {
            return UploadCore.UploadError.transport(code: NSURLErrorNetworkConnectionLost, message: message)
        }
        if let transport = sdkError.underlyingHTTPNetworkError {
            if let code = transport.httpCode, code == 408 || code == 429 || (500...599).contains(code) {
                return UploadCore.UploadError.retryableBackend(code: code, message: message)
            }
            switch transport.errorType {
            case .userAuthenticationError, .configurationLimitExceeded:
                return UploadCore.UploadError.backend(message)
            default:
                return UploadCore.UploadError.transport(
                    code: NSURLErrorNetworkConnectionLost,
                    message: message
                )
            }
        }
        if let api = sdkError.underlyingAPINetworkError,
            let code = api.httpCode,
            code == 408 || code == 429 || (500...599).contains(code)
        {
            return UploadCore.UploadError.retryableBackend(code: code, message: message)
        }
        return UploadCore.UploadError.backend(message)
    }

    /// Maps SDK 0.25's normalized local-file failures into the existing queue domains. In
    /// particular, low disk space reuses the backup runner's durable resource-pressure policy.
    nonisolated static func uploadFileSystemError(
        _ code: ProtonDriveSDKError.FileSystemErrorCode,
        filename: String
    ) -> (any Error)? {
        switch code {
        case .notFound:
            UploadCore.UploadError.fileMissing(filename)
        case .permissionDenied:
            UploadCore.UploadError.permissionDenied(filename)
        case .outOfSpace:
            BackupTempFileStore.BackupTempFileError.diskBudgetExceeded
        case .unknown:
            nil
        }
    }

    private nonisolated static func isSDKCancellation(_ error: Error) -> Bool {
        (error as? ProtonDriveSDKError)?.domain == .successfulCancellation
    }

    func cancel(token: UUID) async {
        _ = try? await withOpenSession { bridge in
            do {
                try await bridge.photosClient.cancelUpload(with: token)
            } catch {
                // The SDK cancellation owner releases its token even when native cancellation fails.
                // Keep the queue's nonthrowing control seam, but preserve evidence for diagnostics.
                DebugLog.log("[Upload] native cancellation failed token=\(token) err=\(error)")
            }
        }
    }
}

// MARK: - Series (burst) writes

extension DriveSDKBridge: PhotoTagAdding {
    func addTags(_ tags: [Int], to uid: PhotoUID) async throws {
        try await withOpenSession { bridge in
            // Backup may know only the main photo's link id; see `PhotoUploadRequest.mainPhotoUID`.
            let volumeID = uid.volumeID.isEmpty ? try await bridge.resolvePhotosRoot().volumeID : uid.volumeID
            try await SDKPhotoTagAdder(client: bridge.photosClient).addTags(
                tags.compactMap(ProtonDriveSDK.PhotoTag.init(rawValue:)),
                to: SDKNodeUid(volumeID: volumeID, nodeID: uid.nodeID)
            )
        }
    }
}

extension DriveSDKBridge: EditReplacementRemote {}

extension DriveSDKBridge: ExactDuplicateRemote {
    /// The person merges duplicates, so the duplicates take the person's trash path.
    func trashDuplicates(_ uids: [PhotoUID]) async throws {
        try await trash(uids)
    }

    func restoreDuplicates(_ uids: [PhotoUID]) async throws {
        try await restore(uids)
    }

    /// Reads the stored timeline, so ranking the photo to keep costs no request.
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] {
        let items = (try? await withOpenSession { bridge in bridge.timelineStore?.items(for: uids) ?? [] }) ?? []
        return Dictionary(items.map { ($0.uid, $0.captureTime) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads the node of each photo, so only the members of the groups that the screen ranks or merges cost a read.
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        guard !uids.isEmpty else { return [:] }
        return try await makeAlbumCatalogBackend().nodeFacts(of: uids)
    }
}

extension DriveSDKBridge: SeriesDissolutionRemote {
    func ownPhotosVolumeID() async throws -> String {
        try await withOpenSession { bridge in
            try await bridge.resolvePhotosRoot().volumeID
        }
    }

    func source(for member: PhotoUID) async throws -> SeriesMemberSource {
        try await withOpenSession { bridge in
            try await SDKPhotoMetadataReader.seriesMemberSource(for: member, client: bridge.photosClient)
        }
    }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        try await withOpenSession { bridge in
            let active = try await bridge.activeNodeIDs(Set(uids.map(\.nodeID)))
            return Set(uids.filter { active.contains($0.nodeID) })
        }
    }

    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        guard !uids.isEmpty else { return [] }
        // One tag listing per operation. Proton exposes no per-node tag read, and the series is small.
        let favorites = try await favoriteUIDs()
        return Set(uids.filter(favorites.contains))
    }

    func markFavorite(_ uids: [PhotoUID]) async throws {
        // `setFavorites` throws unless every node confirms the tag, so a partial write never counts as success.
        try await setFavorites(uids, true)
    }

    /// The series dissolution moves the photos of a dissolved series to the trash. This is no deletion by the person.
    func trashSeries(_ uids: [PhotoUID]) async throws {
        try await moveToTrash(uids)
        try await withOpenSession { bridge in
            // The cached bursts listing still names the trashed series; the next lookup must read it again.
            bridge.burstCatalogEntries = nil
            bridge.burstCatalogLookup = [:]
        }
    }

    /// The dissolution of this account's series. It shares the duplicate service with uploads, so both see
    /// one remote content index. Nil when the upload manifest is unavailable, as uploads are then disabled.
    nonisolated func makeSeriesDissolution(
        duplicateChecker: (any UploadDuplicateChecking)?,
        albums: any SeriesAlbumCarryOver
    ) -> SeriesDissolutionOrchestrator? {
        guard let duplicateChecker else { return nil }
        let accountDataDirectory = uploadManifestURL.deletingLastPathComponent()
        return SeriesDissolutionOrchestrator(
            remote: self,
            albums: albums,
            uploader: self,
            duplicateChecker: duplicateChecker,
            journalStore: SeriesDissolutionJournalFileStore(accountDataDirectory: accountDataDirectory),
            // The shared account gate: bridge teardown cancels and joins a running dissolution before the
            // sign-out purge removes the journal directory.
            admission: shutdownGate,
            tempDirectory: accountDataDirectory.appendingPathComponent("series-dissolution-temp", isDirectory: true),
            currentClientUID: uploadClientUID
        )
    }
}

enum DriveBridgeError: LocalizedError {
    case noPhotosShare
    var errorDescription: String? {
        switch self {
        case .noPhotosShare: String(localized: "error.no_photos_library")
        }
    }
}

/// The SDK reported that this event scope is no longer accessible. Retrying the same scope cannot
/// recover, so the shared monitor stops until account lifecycle creates a new backend instance.
private struct DriveEventScopeAccessLostError: LocalizedError, LibraryChangeTerminalError {
    var errorDescription: String? {
        String(localized: "error.no_photos_library")
    }
}

/// Thread-safe one-shot data holder for the SDK thumbnail callback.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    func set(_ data: Data) { lock.withLock { _data = data } }
    var value: Data? { lock.withLock { _data } }
}

/// Thread-safe collector for per-item and stream-level failures of one thumbnail batch.
private final class BatchFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var itemErrors: [PhotoUID: String] = [:]
    private var streamError: String?

    func recordItem(_ uid: PhotoUID, reason: String) {
        lock.withLock { itemErrors[uid] = reason }
    }

    func recordStream(_ reason: String) {
        lock.withLock { if streamError == nil { streamError = reason } }
    }

    var result: ThumbnailBatchLoadResult {
        lock.withLock { ThumbnailBatchLoadResult(batchError: streamError, itemErrors: itemErrors) }
    }
}

/// Holds the observer that authorizes identities outside every source inventory. The box is set once at
/// composition time and read from the actor, so it needs no isolation of its own.
final class IdentitiesOutsideInventoryObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable ([PhotoUID], UInt64) async -> Void)?

    func set(_ observer: @escaping @Sendable ([PhotoUID], UInt64) async -> Void) {
        lock.withLock { self.observer = observer }
    }

    func report(_ uids: [PhotoUID], sequence: UInt64) async {
        guard let observer = lock.withLock({ observer }) else { return }
        await observer(uids, sequence)
    }
}

extension DriveSDKBridge: LibrarySyncSupportSource {
    func librarySyncSupportSnapshot(now: Date) -> LibrarySyncSupportSnapshot? {
        guard !isShutDown else { return nil }
        var result = librarySupport
        result.storedPhotoCount = timelineStore?.count()
        result.storedEventCursorAgeSeconds = timelineStore?.validationTokenStoredAt().map {
            max(0, now.timeIntervalSince($0))
        }
        result.photosTrashedHereAwaitingLibrary = recentlyDeleted.photosTrashedHereAwaitingLibraryCount
        return result
    }

    /// A load that ends after shutdown belongs to a signed-out session, so it never reaches the trail that
    /// `unregisterLibrary` cleared.
    private func recordSupportEvent(
        _ kind: SupportEventTrail.Kind, sourcePath: LibrarySyncSupportSnapshot.SourcePath,
        errorKind: LibrarySyncSupportSnapshot.ErrorKind? = nil, count: Int? = nil
    ) {
        guard !isShutDown else { return }
        SupportEventTrail.shared.record(kind, sourcePath: sourcePath, errorKind: errorKind, count: count)
    }

    private static func supportLoadErrorKind(_ error: Error) -> LibrarySyncSupportSnapshot.ErrorKind {
        if error is CancellationError || isSDKCancellation(error) { return .cancellation }
        if error is TimelineInventoryVisibilityError { return .inventoryVisibility }
        if error is DriveEventScopeAccessLostError { return .scopeAccessLost }
        if (error as NSError).domain == NSURLErrorDomain { return .network }
        if error is ProtonDriveSDKError { return .sdk }
        return .unknown
    }
}
