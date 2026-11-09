import AppleSecurityCore
import Foundation
import PhotosCore
import Security
import Testing

@testable import ProtonAuth

/// The session's protection class: iOS saves it readable after the first unlock since a restart, macOS keeps the
/// stricter class, and an item saved with the older class moves in place while it is readable.
@Suite struct SessionAccessibilityTests {
    private let session = ProtonSession(uid: "uid", accessToken: "access", refreshToken: "refresh", keyPassword: "key")

    private func store(
        _ keychain: ClassRecordingKeychain, _ accessibility: AppleKeychainAccessibility
    ) -> SessionKeychainStore {
        SessionKeychainStore(
            service: "session-tests", account: "default", keychain: keychain, accessibility: accessibility)
    }

    @Test(arguments: [AppleKeychainAccessibility.afterFirstUnlockThisDeviceOnly, .whenUnlockedThisDeviceOnly])
    func aSaveWritesTheClassThePlatformChose(_ accessibility: AppleKeychainAccessibility) throws {
        let keychain = ClassRecordingKeychain()
        try store(keychain, accessibility).save(session)
        #expect(keychain.storedClass == accessibility)
    }

    @Test func theDefaultClassStaysTheStricterOne() throws {
        let keychain = ClassRecordingKeychain()
        try SessionKeychainStore(service: "session-tests", account: "default", keychain: keychain).save(session)
        #expect(keychain.storedClass == .whenUnlockedThisDeviceOnly, "macOS keeps the class it had")
    }

    @Test func anOlderItemMovesInPlaceAndIsVerified() throws {
        let keychain = ClassRecordingKeychain()
        let data = try JSONEncoder().encode(session)
        keychain.seed(data, class: .whenUnlockedThisDeviceOnly)

        let result = store(keychain, .afterFirstUnlockThisDeviceOnly).migrateAccessibilityIfNeeded()
        #expect(result == .migrated)
        #expect(keychain.storedClass == .afterFirstUnlockThisDeviceOnly)
        #expect(keychain.storedData == data, "the same session")
        #expect(!keychain.operations.contains("delete"), "an update in place, never a delete")
        #expect(try store(keychain, .afterFirstUnlockThisDeviceOnly).load() == session)
    }

    @Test func aSecondMigrationChangesNothing() throws {
        let keychain = ClassRecordingKeychain()
        keychain.seed(try JSONEncoder().encode(session), class: .whenUnlockedThisDeviceOnly)
        let store = store(keychain, .afterFirstUnlockThisDeviceOnly)
        #expect(store.migrateAccessibilityIfNeeded() == .migrated)
        let writes = keychain.operations.filter { $0 == "write" }.count

        #expect(store.migrateAccessibilityIfNeeded() == .current)
        #expect(keychain.operations.filter { $0 == "write" }.count == writes, "no second write")
    }

    @Test func aClassThatTheReadBackDoesNotConfirmIsAFailureAndKeepsTheSession() throws {
        let keychain = ClassRecordingKeychain(updateKeepsClass: true)
        let data = try JSONEncoder().encode(session)
        keychain.seed(data, class: .whenUnlockedThisDeviceOnly)

        #expect(store(keychain, .afterFirstUnlockThisDeviceOnly).migrateAccessibilityIfNeeded() == .failed)
        #expect(keychain.storedData == data, "the old item stays readable")
    }

    @Test func changedDataAtTheRightClassIsStillAFailedMigration() throws {
        let keychain = ClassRecordingKeychain(updateChangesData: true)
        keychain.seed(try JSONEncoder().encode(session), class: .whenUnlockedThisDeviceOnly)
        #expect(store(keychain, .afterFirstUnlockThisDeviceOnly).migrateAccessibilityIfNeeded() == .failed)
        #expect(keychain.storedClass == .afterFirstUnlockThisDeviceOnly)
    }

    @Test func anItemThatCannotBeReadYetIsNotWritten() throws {
        let keychain = ClassRecordingKeychain(readStatus: errSecInteractionNotAllowed)
        keychain.seed(try JSONEncoder().encode(session), class: .whenUnlockedThisDeviceOnly)

        #expect(store(keychain, .afterFirstUnlockThisDeviceOnly).migrateAccessibilityIfNeeded() == .unreadable)
        #expect(!keychain.operations.contains("write"))
        #expect(keychain.storedClass == .whenUnlockedThisDeviceOnly)
    }

    @MainActor @Test func aSessionThatCannotBeReadYetKeepsCheckingAndIsNeverASignOut() {
        let storage = StubSessionStorage(
            load: .failure(AppleSecurityError(operation: .read, status: errSecInteractionNotAllowed)))
        let controller = ProtonAuthController(
            store: storage, authenticator: NeverAuthenticator(), lockedReadIsChecking: true)
        #expect(controller.bootstrap() == .checking)
    }

    /// What the background windows learn from one bootstrap; `before` is the read that it replaces.
    @MainActor private func backgroundRead(
        after load: Result<ProtonSession?, any Error>, replacing before: BackgroundSessionRead
    ) -> BackgroundSessionRead {
        let reads = BackgroundAccountReadiness(grace: {})
        reads.record(before)
        let controller = ProtonAuthController(
            store: StubSessionStorage(load: load), authenticator: NeverAuthenticator(), lockedReadIsChecking: true,
            sessionReads: reads)
        controller.bootstrap()
        return reads.lastRead
    }

    @MainActor @Test func aReadSessionTellsTheBackgroundWindowsThatTheSignInIsReadable() {
        #expect(backgroundRead(after: .success(session), replacing: .unreadable) == .readable)
    }

    @MainActor @Test func aMissingSessionTellsTheBackgroundWindowsThatNoAccountIsSignedIn() {
        #expect(backgroundRead(after: .success(nil), replacing: .notYet) == .absent)
    }

    @MainActor @Test func aLockDenialTellsTheBackgroundWindowsThatTheReadWasRefused() {
        let denied = AppleSecurityError(operation: .read, status: errSecInteractionNotAllowed)
        #expect(backgroundRead(after: .failure(denied), replacing: .readable) == .unreadable)
    }

    /// Only a missing session means no account; any other failed read keeps the window's bounded wait.
    @MainActor @Test func anotherFailedReadDecidesNothingForTheBackgroundWindows() {
        let failed = AppleSecurityError(operation: .read, status: errSecNotAvailable)
        #expect(backgroundRead(after: .failure(failed), replacing: .absent) == .notYet)
    }

    @MainActor @Test func aDamagedSessionDecidesNothingForTheBackgroundWindows() {
        let keychain = ClassRecordingKeychain()
        keychain.seed(Data("not a session".utf8), class: .afterFirstUnlockThisDeviceOnly)
        let reads = BackgroundAccountReadiness(grace: {})
        reads.record(.absent)
        let controller = ProtonAuthController(
            store: store(keychain, .afterFirstUnlockThisDeviceOnly), authenticator: NeverAuthenticator(),
            lockedReadIsChecking: true, sessionReads: reads)
        controller.bootstrap()
        #expect(reads.lastRead == .notYet)
    }

    @MainActor @Test func withoutBackgroundLaunchesALockDenialReportsASignOutAsBefore() {
        // macOS has no launch on a device locked since its restart; a state that keeps checking would never retry.
        let storage = StubSessionStorage(
            load: .failure(AppleSecurityError(operation: .read, status: errSecInteractionNotAllowed)))
        let controller = ProtonAuthController(store: storage, authenticator: NeverAuthenticator())
        guard case .signedOut(let error) = controller.bootstrap() else {
            Issue.record("the default keeps the behavior from before")
            return
        }
        #expect(error != nil)
    }

    @MainActor @Test func aDamagedSessionReportsASignOutAndStaysStored() {
        let keychain = ClassRecordingKeychain()
        let damaged = Data("not a session".utf8)
        keychain.seed(damaged, class: .afterFirstUnlockThisDeviceOnly)
        let controller = ProtonAuthController(
            store: store(keychain, .afterFirstUnlockThisDeviceOnly), authenticator: NeverAuthenticator(),
            lockedReadIsChecking: true)
        guard case .signedOut(let error) = controller.bootstrap() else {
            Issue.record("a damaged item cannot become readable by waiting")
            return
        }
        #expect(error != nil)
        #expect(keychain.storedData == damaged, "the item stays where it is")
        #expect(!keychain.operations.contains("delete"))
        #expect(!keychain.operations.contains("write"))
    }

    @MainActor @Test func anotherReadFailureStillReportsItself() {
        let storage = StubSessionStorage(
            load: .failure(AppleSecurityError(operation: .read, status: errSecNotAvailable)))
        let controller = ProtonAuthController(store: storage, authenticator: NeverAuthenticator())
        guard case .signedOut(let error) = controller.bootstrap() else {
            Issue.record("another read failure keeps today's behavior")
            return
        }
        #expect(error != nil)
    }

    @MainActor @Test func anotherReadFailureStillReportsItselfWithLockedReadChecking() {
        let storage = StubSessionStorage(
            load: .failure(AppleSecurityError(operation: .read, status: errSecNotAvailable)))
        let controller = ProtonAuthController(
            store: storage, authenticator: NeverAuthenticator(), lockedReadIsChecking: true)
        guard case .signedOut(let error) = controller.bootstrap() else {
            Issue.record("only interaction-not-allowed keeps checking")
            return
        }
        #expect(error != nil)
    }

    @MainActor @Test func aFailedMigrationKeepsThePersonSignedIn() {
        let storage = StubSessionStorage(load: .success(session), migration: .failed)
        let controller = ProtonAuthController(store: storage, authenticator: NeverAuthenticator())
        #expect(controller.bootstrap() == .signedIn(session))
        #expect(storage.migrations == 1, "the bootstrap of a readable session tries the migration")
    }
}

/// A generic-password item that keeps its class, keyed by service and account as the real Keychain is.
private final class ClassRecordingKeychain: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var itemClass: AppleKeychainAccessibility?
    private var recorded: [String] = []
    private let readStatus: OSStatus?
    private let updateKeepsClass: Bool
    private let updateChangesData: Bool

    init(readStatus: OSStatus? = nil, updateKeepsClass: Bool = false, updateChangesData: Bool = false) {
        self.readStatus = readStatus
        self.updateKeepsClass = updateKeepsClass
        self.updateChangesData = updateChangesData
    }

    var storedData: Data? { lock.withLock { data } }
    var storedClass: AppleKeychainAccessibility? { lock.withLock { itemClass } }
    var operations: [String] { lock.withLock { recorded } }

    func seed(_ data: Data, class itemClass: AppleKeychainAccessibility) {
        lock.withLock {
            self.data = data
            self.itemClass = itemClass
        }
    }

    func data(for item: AppleKeychainItem) throws -> Data? {
        if let readStatus { throw AppleSecurityError(operation: .read, status: readStatus) }
        return lock.withLock {
            recorded.append("read")
            return data
        }
    }

    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        lock.withLock {
            recorded.append("write")
            if self.data == nil || !updateKeepsClass { itemClass = item.accessibility }
            self.data = updateChangesData ? Data("different session".utf8) : data
        }
    }

    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        if let existing = try self.data(for: item) { return existing }
        try setData(data, for: item)
        return data
    }

    func removeData(for item: AppleKeychainItem) throws {
        lock.withLock {
            recorded.append("delete")
            data = nil
            itemClass = nil
        }
    }

    func removeAllData(service: String) throws {
        try removeData(
            for: AppleKeychainItem(
                service: service, account: "default", accessibility: .whenUnlockedThisDeviceOnly))
    }

    func accessibility(for item: AppleKeychainItem) throws -> AppleKeychainAccessibility? {
        lock.withLock { data == nil ? nil : itemClass }
    }
}

private final class StubSessionStorage: ProtonSessionStorage, @unchecked Sendable {
    private let loadResult: Result<ProtonSession?, any Error>
    private let migration: SessionKeychainStore.AccessibilityMigration
    private let lock = NSLock()
    private var migrationCalls = 0

    init(load: Result<ProtonSession?, any Error>, migration: SessionKeychainStore.AccessibilityMigration = .current) {
        loadResult = load
        self.migration = migration
    }

    var migrations: Int { lock.withLock { migrationCalls } }

    func load() throws -> ProtonSession? { try loadResult.get() }
    func save(_ session: ProtonSession) throws {}
    func clear() throws {}
    func migrateAccessibilityIfNeeded() -> SessionKeychainStore.AccessibilityMigration {
        lock.withLock { migrationCalls += 1 }
        return migration
    }
}

private struct NeverAuthenticator: ProtonAuthenticating {
    func authenticate(
        openURL: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession {
        throw CancellationError()
    }
}
