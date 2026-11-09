import AppleSecurityCore
import PhotosCore
import ProtonAuth
import Security
import SwiftUI
import Testing
import UIKit

@testable import EncryptedMemoriesMobile

/// Account-versus-scene ownership contracts for several iPad windows.
@Suite(.serialized) @MainActor struct MobileSceneOwnershipTests {
    @Test func applicationManifestSupportsMultipleScenes() throws {
        let manifest = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        if UIDevice.current.userInterfaceIdiom == .pad {
            #expect(UIApplication.shared.supportsMultipleScenes)
        }
    }

    @Test func accountRuntimeIsOneProcessWideOwner() {
        #expect(MobileAccountRuntime.shared === MobileAccountRuntime.shared)
        #expect(MobileAccountRuntime.shared.sessionModel === MobileAccountRuntime.shared.sessionModel)
        #expect(MobileAccountRuntime.shared.libraryModel === MobileAccountRuntime.shared.libraryModel)
    }

    /// A session model around a test item, so no test configures a second owner around the saved session.
    private static func isolatedSessionModel() -> MobileSessionModel {
        MobileSessionModel(
            isolatedStore: SessionKeychainStore(
                service: "scene-ownership-tests-\(UUID().uuidString)", account: "default",
                accessibility: .afterFirstUnlockThisDeviceOnly))
    }

    @Test func theAppSavesTheSessionReadableAfterTheFirstUnlock() {
        #expect(MobileAccountRuntime.shared.sessionModel.sessionStore.accessibility == .afterFirstUnlockThisDeviceOnly)
    }

    @Test func authenticationFactoryUsesTheProductionProtectedDataPolicy() {
        let factory = MobileSessionModel.AuthenticationFactory()
        #expect(factory.lockedReadIsChecking)
        #expect(factory.protectedDataSource == \UIApplication.isProtectedDataAvailable)
        #expect(
            UIApplication.shared[keyPath: factory.protectedDataSource] == UIApplication.shared.isProtectedDataAvailable)
    }

    @Test func authenticationFactoryKeepsALockedSessionReadChecking() {
        let store = SessionKeychainStore(
            service: "factory-locked-read-tests", account: "default", keychain: LockedReadKeychain(),
            accessibility: .afterFirstUnlockThisDeviceOnly)
        let authentication = MobileSessionModel.AuthenticationFactory().make(store: store)
        #expect(authentication.controller.bootstrap() == .checking, "the factory passes the locked-read policy")
    }

    /// A runtime without scenes whose Smart Search state changes are recorded, so a test reaches no shared coordinator.
    private static func isolatedRuntime(recording states: ValueRecorder<Bool>) -> MobileAccountRuntime {
        MobileAccountRuntime(
            sessionModel: isolatedSessionModel(), libraryModel: MobileLibraryModel(), connectedScenes: { [] },
            smartSearchForegroundChanged: { states.append($0) })
    }

    @Test func aStartWithoutASceneIsNotForegroundActivity() {
        let states = ValueRecorder<Bool>()
        let runtime = Self.isolatedRuntime(recording: states)
        runtime.start()
        #expect(!runtime.libraryModel.applicationIsActive, "a background window starts no foreground polling")
        #expect(states.values == [false], "Smart Search learns that the app is not in the foreground")
        #expect(runtime.appliedOpportunity == nil, "the first scene applies its phase")
    }

    @Test func aSecondStartFromABackgroundWindowStartsNothingAgain() {
        // A background window and a scene both start the account; only the first start installs anything.
        let runtime = Self.isolatedRuntime(recording: ValueRecorder<Bool>())
        runtime.start()
        let observers = runtime.sceneObserverCount
        #expect(runtime.isStarted)
        #expect(observers > 0)

        runtime.start()
        #expect(runtime.sceneObserverCount == observers, "the second start installs no second set of observers")
    }

    @Test func aggregateSceneActivityReachesTheSharedRuntimeOnlyOnChange() {
        // The test host already owns the process session model; only the library model is isolated here.
        let runtime = MobileAccountRuntime(
            sessionModel: MobileAccountRuntime.shared.sessionModel, libraryModel: MobileLibraryModel())
        #expect(runtime.appliedOpportunity == nil)

        runtime.noteScene("a", phase: .active)
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(LibraryRuntimeState.shared.snapshot().executionOpportunity == .foregroundActive)

        // A second window that opens and then goes to the background must not demote the active account.
        runtime.noteScene("b", phase: .inactive)
        runtime.noteScene("b", phase: .background)
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(runtime.sceneLedger.sceneCount == 2)

        runtime.noteScene("a", phase: .inactive)
        #expect(runtime.appliedOpportunity == .foregroundInactive)
        #expect(LibraryRuntimeState.shared.snapshot().executionOpportunity == .foregroundInactive)

        runtime.noteScene("a", phase: .background)
        #expect(runtime.appliedOpportunity == .backgroundPermitted)

        // Closing the background window while another window returns to the foreground keeps the account
        // in the foreground; only that scene leaves the ledger.
        runtime.noteScene("a", phase: .active)
        runtime.noteSceneDisconnected("b")
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(runtime.sceneLedger.sceneCount == 1)
        #expect(runtime.sceneLedger.phase(of: "b") == nil)

        // The test runtime never observes UIKit scenes; restore the process default for other suites.
        runtime.noteScene("a", phase: .active)
    }

    @Test func sceneContextResolvesItsOwnWindowAndPresenter() async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let firstContext = MobileSceneContext()
        let secondContext = MobileSceneContext()
        let firstWindow = UIWindow(windowScene: scene)
        let secondWindow = UIWindow(windowScene: scene)
        firstWindow.rootViewController = UIHostingController(
            rootView: Color.clear.mobileSceneWindowAnchor(firstContext))
        secondWindow.rootViewController = UIHostingController(
            rootView: Color.clear.mobileSceneWindowAnchor(secondContext))
        firstWindow.makeKeyAndVisible()
        secondWindow.isHidden = false
        defer {
            firstWindow.isHidden = true
            secondWindow.isHidden = true
            firstWindow.rootViewController = nil
            secondWindow.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while firstContext.window !== firstWindow || secondContext.window !== secondWindow,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(firstContext.window === firstWindow)
        #expect(secondContext.window === secondWindow)
        #expect(firstContext.topmostPresenter === firstWindow.rootViewController)
        #expect(secondContext.topmostPresenter === secondWindow.rootViewController)
        #expect(firstContext.topSafeAreaInset == firstWindow.safeAreaInsets.top)
        #expect(MobileSceneContext().window == nil)
        #expect(MobileSceneContext().topmostPresenter == nil)
    }

    @Test func settingsPresentationBelongsToTheScene() {
        let first = MobileSceneContext()
        let second = MobileSceneContext()
        first.settingsPresented = true
        #expect(first.settingsPresented)
        #expect(!second.settingsPresented)
    }

    /// Opens a real second window scene of the production app, verifies that it attaches to the one account
    /// runtime, then closes it and verifies that the account survives the closed window. Where the platform
    /// cannot close the scene, the test keeps every attach assertion and skips only the ledger departure.
    @Test func secondWindowSceneAttachesToAndDetachesFromTheSharedAccount() async throws {
        guard UIApplication.shared.supportsMultipleScenes else {
            return
        }
        let runtime = MobileAccountRuntime.shared
        let sessionModel = runtime.sessionModel
        let libraryModel = runtime.libraryModel
        let existing = Set(UIApplication.shared.connectedScenes.map(\.session.persistentIdentifier))
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication)) {
            error in
            Issue.record("second scene activation failed: \(error)")
        }

        var second: UIWindowScene?
        for _ in 0..<50 where second == nil {
            try await Task.sleep(for: .milliseconds(200))
            second =
                UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { !existing.contains($0.session.persistentIdentifier) }
        }
        let secondScene = try #require(second, "the platform must connect a second window scene")
        let secondID = secondScene.session.persistentIdentifier
        defer { UIApplication.shared.requestSceneSessionDestruction(secondScene.session, options: nil) }
        try await Task.sleep(for: .seconds(2))

        #expect(runtime.isStarted)
        #expect(runtime.sceneLedger.phase(of: secondID) != nil, "the new scene must report into the account ledger")
        #expect(runtime.sceneLedger.sceneCount >= 2)
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(MobileAccountRuntime.shared.sessionModel === sessionModel)
        #expect(MobileAccountRuntime.shared.libraryModel === libraryModel)
        let secondWindow = try #require(secondScene.windows.first)
        #expect(secondWindow.rootViewController != nil, "the second window must host the production root")
        let firstScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { existing.contains($0.session.persistentIdentifier) })
        #expect(firstScene.windows.first?.rootViewController != nil)
        #expect(firstScene.windows.first !== secondWindow)
        writeSnapshot(of: secondWindow, name: "second-window-scene")
        if let firstWindow = firstScene.windows.first {
            writeSnapshot(of: firstWindow, name: "first-window-scene")
        }

        // The attach assertions above hold wherever a second scene connects. A closed window can be checked only
        // where the platform closes the scene; the platform's answer decides, never the device idiom.
        switch await MobileSceneCloser.close(secondScene) {
        case .closed:
            for _ in 0..<50 where runtime.sceneLedger.phase(of: secondID) != nil {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(runtime.sceneLedger.phase(of: secondID) == nil, "a closed window leaves the ledger")
        case .refused(let reason):
            print("scene destruction refused by the platform, ledger departure not checked: \(reason)")
        }
        #expect(runtime.isStarted, "closing a window must not stop the account runtime")
        #expect(MobileAccountRuntime.shared.libraryModel === libraryModel)
        // Bring the original window back to the foreground, as the user would by tapping it. The simulator does
        // not always re-activate it on its own, and later suites need an active application state.
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: firstScene.session)) {
            error in
            Issue.record("first scene re-activation failed: \(error)")
        }
        for _ in 0..<50 where firstScene.activationState != .foregroundActive {
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(firstScene.activationState == .foregroundActive)
        #expect(
            runtime.appliedOpportunity == .foregroundActive,
            "the remaining window drives the account: \(String(describing: runtime.appliedOpportunity))")
    }

    private func writeSnapshot(of window: UIWindow, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else {
            return
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url.appendingPathComponent("\(name).png"))
    }
}

/// Records values on the main actor.
@MainActor private final class ValueRecorder<Value> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// Supplies a locked read without accessing the system Keychain.
private struct LockedReadKeychain: AppleKeychainStoring {
    private enum UnexpectedOperation: Error { case called }

    func data(for item: AppleKeychainItem) throws -> Data? {
        throw AppleSecurityError(operation: .read, status: errSecInteractionNotAllowed)
    }

    func setData(_ data: Data, for item: AppleKeychainItem) throws { throw UnexpectedOperation.called }
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data { throw UnexpectedOperation.called }
    func removeData(for item: AppleKeychainItem) throws { throw UnexpectedOperation.called }
    func removeAllData(service: String) throws { throw UnexpectedOperation.called }
    func accessibility(for item: AppleKeychainItem) throws -> AppleKeychainAccessibility? {
        throw UnexpectedOperation.called
    }
}
