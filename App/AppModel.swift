import AppKit
import Foundation
import LibrarySourceRuntime
import MLSearchAppleAdapter
import MLSearchBackgroundAppleAdapter
import MLSearchCore
import MLSearchFeature
import MapFeature
import MediaByteCache
import MediaFeedCore
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveBackend
import TimelineCore
import UploadCore

@MainActor private struct MacAccountOwners {
    let backend: Task<Void, Never>?
    let scopeRecovery: Task<Void, Never>?
    let facade: ProtonClientFacade?
    let folderBackup: FolderBackupController?
    let photoBackup: PhotoLibraryBackupController?
    let pending: RetiredPendingGrid
    let albumSync: AlbumSyncController?
    let smartSearch: AppleSmartSearchSession
    let sourceAnalysis: LibrarySourceAnalysisSession
    let assets: MLAssetUniverse
    var smartSearchShutdown: Task<Void, Never>?
    var sourceAnalysisShutdown: Task<Void, Never>?

    func makeCoordinator(
        signingOut: Bool, purge: @escaping AccountOwnerGraphFactory.Shutdown
    ) throws -> AccountTeardownCoordinator {
        let location: AccountOwnerGraphFactory.Shutdown? =
            signingOut
            ? { @MainActor @Sendable in
                await OfflineLibraryManager.shared.stopForAccountTeardown()
            } : nil
        let closePendingSession: AccountOwnerGraphFactory.Shutdown? = pending.session.map { session in
            { @MainActor @Sendable in await session.close() }
        }
        // The purge deletes the account directory; the pending store must be closed first.
        let closePendingStore: AccountOwnerGraphFactory.Shutdown? = pending.store.map { store in
            { @MainActor @Sendable in store.close() }
        }
        return try AccountOwnerGraphFactory.makeCoordinator(
            profile: signingOut ? .macSignOut : .macScopeRecovery,
            platformTasks: {
                await backend?.value
                if signingOut {
                    await scopeRecovery?.value
                } else {
                    await OfflineLibraryManager.shared.stopForAccountTeardown()
                }
            },
            smartSearch: {
                await smartSearchShutdown?.value
                await sourceAnalysisShutdown?.value
            }, locationCrawl: location, folderBackup: { await folderBackup?.shutdown() },
            closePendingSession: closePendingSession,
            photoBackup: { await photoBackup?.shutdown() }, closePendingStore: closePendingStore,
            albumSync: { await albumSync?.shutdown() }, facade: { await facade?.shutdown() },
            caches: { await OfflineLibraryManager.shared.purgeCachesForAccountTeardown() },
            logs: { await DebugLog.flush() }, purge: purge)
    }
}

/// Root application state + composition. Owns the session lifecycle and builds the SDK-backed
/// services once the user is signed in.
@MainActor
@Observable
final class AppModel {
    private enum TeardownFailure: Error {
        case purgeClaimUnavailable
        case purgeFailed
    }

    enum AuthState: Equatable {
        case checking
        case signingOut
        case signOutFailed
        case signedOut(error: String?)
        case authenticating(status: String)
        case signedIn(ProtonSession)
    }

    enum BackendState {
        case idle
        case preparing(String)
        case ready(any PhotosBackend)
        case failed(String)
    }

    /// Native Settings navigation; no persisted preference or account behavior.
    var selectedSettingsTab: MacSettingsTabs.Tab.ID = .account

    private(set) var auth: AuthState = .checking
    private(set) var backend: BackendState = .idle
    /// High-level client composition (uploads + albums), built alongside the backend.
    private(set) var facade: ProtonClientFacade? {
        didSet {
            guard facade !== oldValue else { return }
            duplicatesLifetime.retire()
            // The Duplicates screen scans only when it opens, and a library window may not be open. A merge that the
            // end of the app left open is checked now; a new account or a sign-out ends the check of the earlier one.
            duplicatesLifetime.checkPendingMerges(of: facade?.exactDuplicates)
        }
    }
    @ObservationIgnored private let duplicatesLifetime = ExactDuplicatesAccountLifetime()
    /// macOS folder-backup composition. This type owns folder access and lifecycle; sync semantics stay in core.
    private(set) var backupController: FolderBackupController?
    private(set) var photoBackupController: PhotoLibraryBackupController?
    /// The pending grid of this account and its lists, shared with iOS. `PendingGridConnection` describes each one.
    @ObservationIgnored private let pendingGridConnection = PendingGridConnection()
    var pendingGrid: PendingGridSession? { pendingGridConnection.session }
    /// The presentation callback for `session`: it calls `apply` only while the connection shows that session.
    func pendingPresentationHandler(
        for session: PendingGridSession, apply: @escaping (PendingTimelinePresentation) -> Void
    ) -> (PendingTimelinePresentation) -> Void {
        pendingGridConnection.presentationHandler(for: session, apply: apply)
    }
    var pendingTrash: PendingTrashPresentation { pendingGridConnection.trash }
    var excludedPendingTiles: [PendingTile] { pendingGridConnection.excludedTiles }
    var pendingFavoriteRevision: UInt64 { pendingGridConnection.favoriteRevision }
    private(set) var albumSyncController: AlbumSyncController?
    /// Bumped after album sync creates or mutates Proton albums. Views use it only to refresh
    /// visible album lists; sync correctness lives in the shared controller.
    private(set) var albumCatalogRevision = 0
    /// Wakes analysis-only presentation after a source inventory becomes readable.
    private(set) var sourceAnalysisRevision: UInt64 = 0
    /// Account-scoped Smart Search session. Lifecycle decisions stay in MLSearchCore.
    @ObservationIgnored private let smartSearchSession = AppleSmartSearchSession(
        backgroundHost: AppleSmartSearchBackgroundCoordinator.shared
    )
    var smartSearch: MLSmartSearchController? { smartSearchSession.controller }
    let searchSuggestions = SmartSearchDiscoveryScheduler { latitude, longitude in
        await NativePlaceNameResolver.shared.cityName(latitude: latitude, longitude: longitude)
    }
    private var smartSearchAssets: MLAssetUniverse { smartSearchSession.assets }
    @ObservationIgnored private let sourceAnalysis = LibrarySourceAnalysisSession()
    @ObservationIgnored private var onPrimaryInventoryFailure: (@MainActor () -> Void)?
    @ObservationIgnored private let signOutBarrier = AccountSignOutBarrier()
    /// Retains the idempotent purge after a failure. The durable marker independently recreates this claim
    /// after process termination, before session bootstrap opens any account-owned store.
    @ObservationIgnored private var pendingSignOutPurgeClaim: BackupLocalDataPurge.Claim?
    /// Indicates that the first signed-in library load reached a terminal state. The launch veil lifts only
    /// after the grid is ready, and this flag resets for sign-out and each new backend build.
    private(set) var libraryReady = false

    /// Controls whether the persistent launch surface shows its loading content while the app prepares the
    /// session/library. The login screen keeps that same frosted surface mounted but is not itself preparation.
    var isPreparing: Bool {
        switch auth {
        case .checking:
            return true
        case .signingOut, .signOutFailed, .signedOut, .authenticating:
            return false
        case .signedIn:
            switch backend {
            case .idle, .preparing:
                return true
            case .failed:
                return false
            case .ready:
                return facade == nil || !libraryReady
            }
        }
    }

    var hasAuthenticatedAccount: Bool {
        if case .signedIn = auth { return true }
        return false
    }

    /// Called by the main UI once the timeline has settled (loaded / empty / failed) so the launch veil fades.
    func markLibraryReady() { libraryReady = true }

    private let sessionStore: SessionKeychainStore
    private let authController: ProtonAuthController
    /// The startup and sign-in guard shared with iOS: no session starts before the sign-out purge and cleanup ended.
    private let startupCleanup = ProtonAuthStartupCleanup()
    private var didBootstrap = false
    private let webAuthenticationSession = ManagedWebAuthenticationSession()
    private let webAuthenticationPresentationContext = ManagedWebAuthenticationPresentationContext {
        guard
            let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
        else {
            preconditionFailure("Web authentication requires a visible application window")
        }
        return window
    }
    private let photoBackupScheduler = MacPhotoBackupScheduler()
    private var backendTask: Task<Void, Never>?
    /// One retry of the backend at a time; the failed preparation ends before the next one starts.
    @ObservationIgnored private let backendRetry = BackendRetrySequence()
    private var scopeRecoveryTask: Task<Void, Never>?

    init(startupPlaintextPurgeSucceeded: Bool? = nil) {
        let store = SessionKeychainStore()
        self.sessionStore = store
        self.authController = ProtonAuthController(
            store: store,
            authenticator: ProtonForkAuthenticator(config: .externalDriveEncryptedMemories)
        )
        // Wire ProtonCore's CryptoGo to the patched GopenPGP implementation before any crypto runs.
        injectDefaultCryptoImplementation()
        beginStartupCleanup(plaintextPurgeSucceeded: startupPlaintextPurgeSucceeded)
    }

    private func beginStartupCleanup(plaintextPurgeSucceeded: Bool? = nil, signInAfterCleanup: Bool = false) {
        guard !startupCleanup.isRunning else { return }
        auth = .checking
        startupCleanup.begin(plaintextPurgeSucceeded: plaintextPurgeSucceeded) { [weak self] succeeded in
            guard let self else { return }
            if succeeded, signInAfterCleanup {
                self.signIn()
            } else {
                self.didBootstrap = false
                self.bootstrap()
            }
        }
    }

    /// Restore a persisted session on launch.
    func bootstrap() {
        guard !startupCleanup.isRunning else { return }
        guard !didBootstrap else { return }
        didBootstrap = true
        guard startupCleanup.succeeded else {
            auth = .signedOut(error: L10n.string("auth.sign_in_failed"))
            return
        }
        apply(authController.bootstrap(), prepareBackendOnSignedIn: true)
    }

    func signIn() {
        guard !signOutBarrier.isRunning else { return }
        switch startupCleanup.admitSignIn() {
        case .waitForCleanup:
            return
        case .cleanUpFirst:
            beginStartupCleanup(signInAfterCleanup: true)
            return
        case .proceed:
            break
        }
        authController.signIn(
            openURL: { [weak self] url in
                Task { @MainActor [weak self] in
                    self?.startWebAuthenticationSession(url: url)
                }
            },
            onStateChange: { [weak self] state in
                self?.apply(state, prepareBackendOnSignedIn: true)
            }
        )
    }

    func cancelSignIn() {
        guard !signOutBarrier.isRunning else { return }
        webAuthenticationSession.cancel()
        apply(authController.cancelSignIn(), prepareBackendOnSignedIn: false)
    }

    private func startWebAuthenticationSession(url: URL) {
        webAuthenticationSession.start(
            url: url,
            presentationContextProvider: webAuthenticationPresentationContext
        ) { [weak self] in
            guard let self, case .authenticating = self.auth else { return }
            self.apply(self.authController.cancelSignIn(), prepareBackendOnSignedIn: false)
        }
    }

    func signOut() {
        guard !signOutBarrier.isRunning else { return }
        LibraryRuntimeState.shared.beginNewGeneration()
        AccountInfo.shared.clear()
        OfflineLibraryManager.shared.prepareForAccountTeardown()
        ProtonAuthStartupCleanup.armPurgeForSignOut()
        let purgeClaim = BackupLocalDataPurge.claimSignOutPurge()
        pendingSignOutPurgeClaim = purgeClaim
        let signedOutState = authController.signOut()
        let active = captureAndCancelTransientOwners(signingOut: true)
        backupController = nil
        photoBackupScheduler.invalidate()
        photoBackupController = nil
        albumSyncController = nil
        albumCatalogRevision = 0
        facade = nil
        libraryReady = false
        let teardownCoordinator: AccountTeardownCoordinator
        do {
            teardownCoordinator = try active.makeCoordinator(signingOut: true) {
                guard let purgeClaim else { throw TeardownFailure.purgeClaimUnavailable }
                PendingReplacementLedger.clearForSignOut()
                let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: purgeClaim)
                guard succeeded else { throw TeardownFailure.purgeFailed }
            }
        } catch {
            preconditionFailure("Duplicate account teardown owner identifier")
        }

        signOutBarrier.begin { [self] in
            let report = await teardownCoordinator.teardown()
            if report.succeeded {
                pendingSignOutPurgeClaim = nil
                apply(signedOutState, prepareBackendOnSignedIn: false)
            } else {
                auth = .signOutFailed
            }
        }
    }

    /// Retries only the purge after every account owner has already shut down. Failure keeps the marker armed.
    func retrySignOutCleanup() {
        guard case .signOutFailed = auth,
            let claim = pendingSignOutPurgeClaim,
            !signOutBarrier.isRunning
        else { return }

        auth = .signingOut
        signOutBarrier.begin { [self] in
            let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: claim)
            if succeeded {
                pendingSignOutPurgeClaim = nil
                apply(.signedOut(error: nil), prepareBackendOnSignedIn: false)
            } else {
                auth = .signOutFailed
            }
        }
    }

    /// Retries a failed preparation. A failed preparation leaves no facade: `prepareBackend` assigns one only after
    /// `makeFacade` succeeded, and a failed scope recovery shut its facade down first. So two backends never work on
    /// the account's files, a retry starts only without a facade, and only after the failed preparation ended.
    func retryBackend() {
        guard scopeRecoveryTask == nil, case .failed = backend, case .signedIn(let session) = auth else { return }
        guard facade == nil else {
            DebugLog.log("backend retry: a failed state still holds a facade; the retry starts nothing")
            assertionFailure("A failed backend state must not hold a facade")
            return
        }
        let failed = backendTask
        Task {
            await backendRetry.run(
                retire: { [weak self] in
                    // A sign-out must still find a preparation that replaced the failed one meanwhile.
                    if self?.backendTask == failed { self?.backendTask = nil }
                    await failed?.value
                },
                start: { [weak self] in
                    // Another preparation that began meanwhile keeps running; the retry starts no second one.
                    guard let self, self.scopeRecoveryTask == nil, self.facade == nil, self.backendTask == nil,
                        case .signedIn(let current) = self.auth, current == session
                    else { return }
                    self.prepareBackend(session)
                })
        }
    }

    /// A terminal Drive scope event invalidates every local projection for that volume. Keep authentication,
    /// but retire all account owners before deleting the SDK, metadata, media, and location caches and rebuilding.
    func recoverBackendAfterScopeAccessLoss() async {
        guard scopeRecoveryTask == nil,
            case .signedIn(let session) = auth
        else { return }

        let active = captureAndCancelTransientOwners(signingOut: false)
        let policy = ProtonDriveBackendPolicy.standard(
            libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy
        )

        backupController = nil
        photoBackupScheduler.invalidate()
        photoBackupController = nil
        albumSyncController = nil
        albumCatalogRevision = 0
        facade = nil
        libraryReady = false

        let coordinator: AccountTeardownCoordinator
        do {
            coordinator = try active.makeCoordinator(signingOut: false) {
                await Task.detached(priority: .utility) {
                    ProtonDriveBackendFactory.purgeLocalAccountData(uid: session.uid, policy: policy)
                }.value
            }
        } catch {
            preconditionFailure("Duplicate scope recovery owner identifier")
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.scopeRecoveryTask = nil }
            let report = await coordinator.teardown()
            guard report.succeeded else {
                DebugLog.log("scope recovery: ordered teardown or purge failed")
                self.backend = .failed(String(localized: "error.library_open_failed"))
                return
            }
            guard !Task.isCancelled,
                case .signedIn(let currentSession) = self.auth,
                currentSession == session
            else { return }
            self.prepareBackend(session)
        }
        scopeRecoveryTask = task
        await task.value
    }

    /// Captures every native owner before cancellation can clear an account slot.
    private func captureAndCancelTransientOwners(signingOut: Bool) -> MacAccountOwners {
        AccountOwnerGraphFactory.captureAndCancel(
            {
                MacAccountOwners(
                    backend: backendTask, scopeRecovery: signingOut ? scopeRecoveryTask : nil,
                    facade: facade, folderBackup: backupController, photoBackup: photoBackupController,
                    pending: pendingGridConnection.retire(), albumSync: albumSyncController,
                    smartSearch: smartSearchSession, sourceAnalysis: sourceAnalysis, assets: smartSearchAssets)
            },
            cancel: { active in
                if signingOut {
                    active.scopeRecovery?.cancel()
                    scopeRecoveryTask = nil
                    auth = .signingOut
                    active.backend?.cancel()
                    backendTask = nil
                    backend = .idle
                }
                searchSuggestions.reset()
                active.smartSearchShutdown = active.smartSearch.stop()
                active.sourceAnalysisShutdown = stopSourceAnalysis()
                if !signingOut {
                    LibraryRuntimeState.shared.beginNewGeneration()
                    OfflineLibraryManager.shared.prepareForAccountTeardown()
                    active.backend?.cancel()
                    backendTask = nil
                    backend = .preparing(String(localized: "loading.building_library"))
                }
            })
    }

    @discardableResult
    private func stopSourceAnalysis() -> Task<Void, Never>? {
        smartSearchAssets.invalidateSourceSession()
        onPrimaryInventoryFailure = nil
        return sourceAnalysis.stop()
    }

    /// Creates the account-scoped Smart Search lifecycle after the feed and timeline are available.
    /// Lifecycle decisions remain in the shared Core actor.
    func configureSmartSearch(
        feedCore: ThumbnailFeedCore,
        primaryItems: [PhotoItem],
        primaryAuthority: SourceInventoryAuthority,
        onPrimaryInventoryFailure: @escaping @MainActor () -> Void
    ) {
        guard let session = authController.currentSession, let facade else { return }
        self.onPrimaryInventoryFailure = onPrimaryInventoryFailure
        if sourceAnalysis.runtime == nil {
            sourceAnalysis.install(
                LibrarySourceAnalysisRuntime(
                    coordinator: facade.librarySources,
                    feed: feedCore,
                    assets: smartSearchAssets,
                    onAssetsChanged: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.sourceAnalysisRevision &+= 1
                            self.smartSearch?.noteLibraryChanged()
                        }
                    }
                ))
            sourceAnalysis.startPrimaryInventory(
                primaryItems,
                authority: primaryAuthority,
                onFailure: { [weak self] in self?.onPrimaryInventoryFailure?() }
            )
        } else {
            sourceAnalysis.replacePrimaryInventory(
                primaryItems,
                authority: primaryAuthority,
                onFailure: { [weak self] in self?.onPrimaryInventoryFailure?() }
            )
        }

        // macOS configures once per MainView life; the session keeps the first lifecycle.
        guard smartSearchSession.controller == nil else { return }
        smartSearchSession.configure(
            accountDirectory: facade.accountDataDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword,
            feed: feedCore,
            databasePolicy: facade.accountDatabasePolicy
        )
    }

    func updateSmartSearchAssets(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority
    ) {
        sourceAnalysis.replacePrimaryInventory(
            items,
            authority: authority,
            onFailure: { [weak self] in self?.onPrimaryInventoryFailure?() }
        )
    }

    func refreshLibrarySources() {
        guard let runtime = sourceAnalysis.runtime else { return }
        Task { await runtime.refresh() }
    }

    func makeDuplicatesModel(
        for facade: ProtonClientFacade,
        didTrash: @escaping @MainActor ([PhotoUID], ExactDuplicatesAccountLifetime.Token) async -> Void
    ) -> ExactDuplicatesModel? {
        guard self.facade === facade, case .ready = backend else { return nil }
        return duplicatesLifetime.replace(with: facade.exactDuplicates, didTrash: didTrash)
    }

    func isCurrentDuplicatesAccount(_ token: ExactDuplicatesAccountLifetime.Token) -> Bool {
        duplicatesLifetime.isCurrent(token)
    }

    private func prepareBackend(_ session: ProtonSession) {
        duplicatesLifetime.retire()
        LibraryRuntimeState.shared.beginNewGeneration()
        backendTask?.cancel()
        libraryReady = false
        searchSuggestions.reset()
        smartSearchSession.stop()
        stopSourceAnalysis()
        // Install the per-account encrypted-cache key derived from the restored session before the grid
        // renders or the crawl begins.
        OfflineLibraryManager.shared.configure(session: session)
        backend = .preparing(String(localized: "loading.building_library"))
        backendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await ProtonDriveBackendFactory.makeFacade(
                    session: session,
                    store: sessionStore,
                    policy: .standard(libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy)
                )
                guard !Task.isCancelled else {
                    await client.shutdown()
                    return
                }
                facade = client
                // The pending store, the photo backup and album sync are built the same way on iOS.
                let stack = AccountBackupStack(
                    accountDataDirectory: client.accountDataDirectory,
                    databasePolicy: client.accountDatabasePolicy,
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    tagAdder: client.photoTagAdder,
                    editReplacement: client.editedPhotoReplacement,
                    albumOperations: client.albumSyncRemoteOps
                )
                let pendingStore = stack.pendingStore
                let photoBackup = stack.photoBackup
                let previousPhotoBackup = photoBackupController
                let previousFolderBackup = backupController
                photoBackupController = photoBackup
                photoBackupScheduler.configure(controller: photoBackup)
                // Watched folders share the pending store and the photo backup's event stream.
                let folderBackup = FolderBackupController(
                    facade: client, pendingStore: pendingStore, pendingRecorder: photoBackup.pendingRecorder,
                    requiresPendingStore: true)
                backupController = folderBackup
                let replacedPendingGrid = configurePendingGrid(
                    store: pendingStore, photoBackup: photoBackup, folderBackup: folderBackup, client: client)
                let albumSync = stack.albumSync
                albumSync.setRemoteAlbumsChangedHandler { [weak self] in
                    self?.albumCatalogRevision &+= 1
                }
                albumSyncController = albumSync
                await client.uploadCoordinator.start()
                // No current flow is known to hand back a non-empty pair here; a second sign-in is not proven
                // unreachable. A pair that a replacing start left is closed here, after every assignment of this
                // block and right before the guard that re-checks the account.
                await replacedPendingGrid.close(
                    beforeSession: { await previousFolderBackup?.shutdown() },
                    whileStoreOpen: { await previousPhotoBackup?.shutdown() })
                guard !Task.isCancelled, facade === client, authController.currentSession == session else { return }
                backend = .ready(client.backend)
                // Register account caches after construction so pressure events can manage their budgets.
                AppMemoryPressureCoordinator.shared.install()
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled, authController.currentSession == session else { return }
                DebugLog.log("backend prepare FAILED: \(error)")
                backend = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Pending grid

    /// Starts the pending grid and returns the session and store that this start replaced. The caller closes them
    /// (`RetiredPendingGrid.close`). The previous folder backup and photo backup controllers, which also write to
    /// that store, shut down only in that close; without a replaced pair nothing shuts them down here.
    private func configurePendingGrid(
        store: PendingBackupManifestStore?,
        photoBackup: PhotoLibraryBackupController,
        folderBackup: FolderBackupController,
        client: ProtonClientFacade
    ) -> RetiredPendingGrid {
        let albums = client.albums
        return pendingGridConnection.start(
            store: store,
            makeSession: { store in
                PendingGridSession(
                    store: store,
                    photoBackup: photoBackup,
                    remote: ProtonPendingRemoteEffects(facade: client),
                    files: folderBackup.pendingFileSource
                )
            },
            albumAdds: { await albums.setPendingAlbumAdds($0) }
        ).replaced
    }

    private func apply(_ state: ProtonAuthState, prepareBackendOnSignedIn: Bool) {
        webAuthenticationSession.follow(state)
        switch state {
        case .checking:
            auth = .checking
        case .signedOut(let error):
            auth = .signedOut(error: error)
        case .authenticating(let progress):
            auth = .authenticating(status: ProtonAuthProgressPresentation.status(for: progress))
        case .signedIn(let session):
            auth = .signedIn(session)
            if prepareBackendOnSignedIn {
                prepareBackend(session)
            }
        }
    }
}
