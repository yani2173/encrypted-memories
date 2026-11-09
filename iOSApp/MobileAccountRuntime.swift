import Combine
import Foundation
import LibraryRuntimeAppleAdapter
import MLSearchBackgroundAppleAdapter
import Observation
import PhotosCore
import ProtonDriveBackend
import TimelineCore
import UIKit

/// The process-wide owner of the signed-in account: one session model, one library model, one runtime.
///
/// Every window scene renders this same account. A scene owns only its UI state (route, selection, search,
/// viewer, presentations); it never creates, configures, or tears down account services. Scene lifecycle
/// signals are aggregated through `LibrarySceneActivityLedger` before they reach the process-wide
/// coordinators, so an inactive or closed window cannot demote work that another visible window still drives.
/// Explicit sign-out remains account-wide and uses the existing ordered teardown/purge contracts.
@MainActor
final class MobileAccountRuntime {
    static let shared = MobileAccountRuntime()

    let sessionModel: MobileSessionModel
    let libraryModel: MobileLibraryModel

    private(set) var sceneLedger = LibrarySceneActivityLedger()
    /// The last opportunity written to the process-wide coordinators; `nil` until the first scene reports.
    private(set) var appliedOpportunity: LibraryExecutionOpportunity?
    private(set) var isStarted = false
    private var sessionSubscription: AnyCancellable?
    private var sceneObservers: [NSObjectProtocol] = []
    private var uploadSignals = UploadRefreshSignalTracker(
        backupRevision: nil, manualRevision: nil, passIsRunning: false)
    private var wasSigningOut = false
    private let connectedScenes: @MainActor () -> Set<UIScene>
    private let smartSearchForegroundChanged: @MainActor (Bool) -> Void

    private init() {
        sessionModel = MobileSessionModel()
        libraryModel = MobileLibraryModel()
        connectedScenes = { UIApplication.shared.connectedScenes }
        smartSearchForegroundChanged = {
            AppleSmartSearchBackgroundCoordinator.shared.applicationStateChanged(isForeground: $0)
        }
    }

    /// An isolated runtime around injected models. `start()` installs scene observers just as the shared runtime does.
    init(
        sessionModel: MobileSessionModel, libraryModel: MobileLibraryModel,
        connectedScenes: @escaping @MainActor () -> Set<UIScene> = { UIApplication.shared.connectedScenes },
        smartSearchForegroundChanged: @escaping @MainActor (Bool) -> Void = {
            AppleSmartSearchBackgroundCoordinator.shared.applicationStateChanged(isForeground: $0)
        }
    ) {
        self.sessionModel = sessionModel
        self.libraryModel = libraryModel
        self.connectedScenes = connectedScenes
        self.smartSearchForegroundChanged = smartSearchForegroundChanged
    }

    /// Idempotent. The first scene root starts the account; later scenes (including simultaneous state
    /// restoration of several windows) attach to the already running runtime.
    func start() {
        logAccountStart(wasRunning: isStarted)
        guard !isStarted else { return }
        isStarted = true
        libraryModel.configure(session: sessionModel.session, store: sessionModel.sessionStore)
        sessionSubscription = sessionModel.$session
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] session in
                guard let self else { return }
                self.libraryModel.configure(session: session, store: self.sessionModel.sessionStore)
            }
        wasSigningOut = libraryModel.isSigningOut
        uploadSignals = UploadRefreshSignalTracker(
            backupRevision: libraryModel.photoBackup?.uploadedLibraryMutationRevision,
            manualRevision: libraryModel.facade?.uploadCoordinator.completedUploadRevision,
            passIsRunning: libraryModel.photoBackup?.isSyncing ?? false)
        observeLibrarySignals()
        installSceneObservers()
    }

    /// The device log of each start call: a scene or a background window, with the scenes that iOS has connected.
    private func logAccountStart(wasRunning: Bool) {
        let state: BackgroundWorkLog.Value =
            switch UIApplication.shared.applicationState {
            case .active: .word("active")
            case .inactive: .word("inactive")
            case .background: .word("background")
            @unknown default: .word("unknown")
            }
        BackgroundWorkLog.system.notice(
            .launch, "account.start",
            [
                (.init("result"), wasRunning ? .word("alreadyRunning") : .word("started")),
                (.init("scenes"), .count(connectedScenes().count)), (.init("appState"), state),
            ])
    }

    // MARK: - Scene activity aggregation

    /// Records one scene's phase and applies the aggregate when it changes.
    func noteScene(_ sceneID: String, phase: LibrarySceneActivityLedger.ScenePhase) {
        apply(sceneLedger.update(sceneID: sceneID, phase: phase))
    }

    /// Closing a window forgets only that scene. Account data and services stay untouched.
    func noteSceneDisconnected(_ sceneID: String) {
        apply(sceneLedger.remove(sceneID: sceneID))
    }

    private func apply(_ opportunity: LibraryExecutionOpportunity) {
        guard opportunity != appliedOpportunity else { return }
        appliedOpportunity = opportunity
        AppleLibraryRuntimeAdapter.shared.setExecutionOpportunity(opportunity)
        AppleSmartSearchBackgroundCoordinator.shared.applicationStateChanged(
            isForeground: opportunity != .backgroundPermitted)
        switch opportunity {
        case .backgroundPermitted, .suspended:
            PhotoBackupBackgroundCoordinator.shared.applicationDidEnterBackground(
                controller: EncryptedMemoriesMobileApp.currentPhotoBackup()
            )
            DuplicatesMergeBackgroundGrace.shared.applicationDidEnterBackground(model: libraryModel.duplicates)
        case .foregroundActive:
            PhotoBackupBackgroundCoordinator.shared.applicationDidBecomeActive(
                controller: EncryptedMemoriesMobileApp.currentPhotoBackup()
            )
            DuplicatesMergeBackgroundGrace.shared.applicationDidBecomeActive(model: libraryModel.duplicates)
            // Foregrounding reopens the background-indexing gate promptly.
            libraryModel.smartSearch?.noteConditionsChanged()
            Task {
                await ProtonAccountInfoRequestCause.foregroundActivation.run {
                    await libraryModel.refreshAccountInfo()
                }
            }
        case .foregroundInactive:
            break
        }
        libraryModel.setApplicationActive(opportunity == .foregroundActive)
    }

    /// The scene observers that `start()` installed, so a test can tell that a second start installs none.
    var sceneObserverCount: Int { sceneObservers.count }

    private func installSceneObservers() {
        let center = NotificationCenter.default
        for scene in connectedScenes() {
            sceneLedger.update(sceneID: Self.sceneID(scene), phase: Self.phase(of: scene.activationState))
        }
        if !sceneLedger.isEmpty {
            apply(sceneLedger.opportunity)
        } else {
            // A start without a scene, from a background window, is not foreground activity: no source refresh or
            // library polling as if the app were open. The first scene that connects applies its phase.
            libraryModel.setApplicationActive(false)
            smartSearchForegroundChanged(false)
        }

        let phaseEvents: [(Notification.Name, LibrarySceneActivityLedger.ScenePhase)] = [
            (UIScene.didActivateNotification, .active),
            (UIScene.willDeactivateNotification, .inactive),
            (UIScene.willEnterForegroundNotification, .inactive),
            (UIScene.didEnterBackgroundNotification, .background),
        ]
        for (name, phase) in phaseEvents {
            sceneObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let scene = notification.object as? UIScene else { return }
                    let sceneID = Self.sceneID(scene)
                    Task { @MainActor [weak self] in self?.noteScene(sceneID, phase: phase) }
                })
        }
        sceneObservers.append(
            center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let scene = notification.object as? UIScene else { return }
                let sceneID = Self.sceneID(scene)
                let phase = Self.phase(of: scene.activationState)
                Task { @MainActor [weak self] in self?.noteScene(sceneID, phase: phase) }
            })
        sceneObservers.append(
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let scene = notification.object as? UIScene else { return }
                let sceneID = Self.sceneID(scene)
                Task { @MainActor [weak self] in self?.noteSceneDisconnected(sceneID) }
            })
    }

    private static func sceneID(_ scene: UIScene) -> String {
        scene.session.persistentIdentifier
    }

    private static func phase(of state: UIScene.ActivationState) -> LibrarySceneActivityLedger.ScenePhase {
        switch state {
        case .foregroundActive: .active
        case .foregroundInactive: .inactive
        case .background, .unattached: .background
        @unknown default: .inactive
        }
    }

    // MARK: - Account-level library signals

    /// Re-arming observation of the account-level signals that previously lived in the scene root view.
    /// They belong to the account: one refresh per local upload, one sign-out completion, regardless of how
    /// many windows show the library.
    private func observeLibrarySignals() {
        withObservationTracking {
            _ = libraryModel.isSigningOut
            _ = libraryModel.photoBackup?.uploadedLibraryMutationRevision
            _ = libraryModel.photoBackup?.isSyncing
            _ = libraryModel.facade?.uploadCoordinator.completedUploadRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.handleLibrarySignals()
                self.observeLibrarySignals()
            }
        }
    }

    private func handleLibrarySignals() {
        let signingOut = libraryModel.isSigningOut
        if wasSigningOut, !signingOut {
            sessionModel.completeSignOutPresentation()
        }
        wasSigningOut = signingOut

        let outcome = uploadSignals.observe(
            backupRevision: libraryModel.photoBackup?.uploadedLibraryMutationRevision,
            manualRevision: libraryModel.facade?.uploadCoordinator.completedUploadRevision,
            passIsRunning: libraryModel.photoBackup?.isSyncing ?? false)
        switch outcome.refresh {
        case .manualUpload: libraryModel.refreshAfterLocalUpload()
        case .backupUpload(let passIsRunning): libraryModel.refreshAfterBackupUpload(passIsRunning: passIsRunning)
        case nil: break
        }
        if outcome.passEnded { libraryModel.backupPassDidEnd() }
    }
}
