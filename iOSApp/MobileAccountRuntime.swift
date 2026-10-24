import Combine
import Foundation
import LibraryRuntimeAppleAdapter
import MLSearchBackgroundAppleAdapter
import Observation
import PhotosCore
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
    private var uploadedLibraryMutationRevision: UInt64?
    private var completedUploadRevision: Int?
    private var wasSigningOut = false

    private init() {
        sessionModel = MobileSessionModel()
        libraryModel = MobileLibraryModel()
    }

    /// Test seam: an isolated runtime around injected models. It never touches UIKit scene notifications.
    init(sessionModel: MobileSessionModel, libraryModel: MobileLibraryModel) {
        self.sessionModel = sessionModel
        self.libraryModel = libraryModel
    }

    /// Idempotent. The first scene root starts the account; later scenes (including simultaneous state
    /// restoration of several windows) attach to the already running runtime.
    func start() {
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
        uploadedLibraryMutationRevision = libraryModel.photoBackup?.uploadedLibraryMutationRevision
        completedUploadRevision = libraryModel.facade?.uploadCoordinator.completedUploadRevision
        observeLibrarySignals()
        installSceneObservers()
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
            Task { await libraryModel.refreshAccountInfo() }
        case .foregroundInactive:
            break
        }
        libraryModel.setApplicationActive(opportunity == .foregroundActive)
    }

    private func installSceneObservers() {
        let center = NotificationCenter.default
        for scene in UIApplication.shared.connectedScenes {
            sceneLedger.update(sceneID: Self.sceneID(scene), phase: Self.phase(of: scene.activationState))
        }
        if !sceneLedger.isEmpty { apply(sceneLedger.opportunity) }

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

        let uploaded = libraryModel.photoBackup?.uploadedLibraryMutationRevision
        let completed = libraryModel.facade?.uploadCoordinator.completedUploadRevision
        if uploaded != uploadedLibraryMutationRevision || completed != completedUploadRevision {
            uploadedLibraryMutationRevision = uploaded
            completedUploadRevision = completed
            libraryModel.refreshAfterLocalUpload()
        }
    }
}
