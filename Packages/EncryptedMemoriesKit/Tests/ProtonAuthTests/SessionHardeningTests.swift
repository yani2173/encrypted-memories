import AppleSecurityCore
import Foundation
import Security
import Testing

@testable import PhotosCore
@testable import ProtonAuth

/// Session secrets must never have a plaintext developer bypass. Tokens and the key password are always
/// stored in the macOS Keychain.
@Suite("Session secret hardening")
struct SessionHardeningTests {
    private func networkStoreLocation(in root: URL) -> UnusedNetworkStorePurge.Location {
        let library = root.appendingPathComponent(
            "Containers/at.oncloud.encryptedmemories/Data/Library", isDirectory: true)
        return UnusedNetworkStorePurge.Location(
            libraryDirectory: library, cachesDirectory: library.appendingPathComponent("Caches", isDirectory: true),
            bundleIdentifier: "at.oncloud.encryptedmemories")
    }

    @Test func appOwnedKeychainServicesUseEncryptedMemoriesNamespace() {
        #if os(macOS)
            #expect(SessionKeychainStore.defaultService == "at.oncloud.encryptedmemories.session")
        #endif
        #expect(DeviceIdentityKeychainStore.defaultService == "at.oncloud.encryptedmemories.device-identity")
    }

    @Test func noDeveloperPlaintextSessionSwitchExists() {
        #expect(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_DEV_PLAINTEXT_SESSION"] == nil)
    }

    @Test func sessionEncodingRoundTripsThroughSharedKeychainContract() throws {
        let keychain = MemoryAppleKeychainStore()
        let store = SessionKeychainStore(
            service: "at.oncloud.encryptedmemories.session.tests-\(UUID().uuidString)",
            account: "default",
            keychain: keychain
        )
        let session = ProtonSession(uid: "uid-test", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        try store.save(session)
        defer { try? store.clear() }

        #expect(try store.load() == session)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func sessionSaveFailsWhenDurableReadBackDoesNotMatch() {
        let keychain = NonPersistingAppleKeychainStore()
        let store = SessionKeychainStore(
            service: "at.oncloud.encryptedmemories.session.tests-\(UUID().uuidString)",
            account: "default",
            keychain: keychain
        )
        let session = ProtonSession(uid: "uid-test", accessToken: "at", refreshToken: "rt", keyPassword: "kp")

        #expect(throws: SessionKeychainError.verificationFailed) {
            try store.save(session)
        }
    }

    @Test func deviceIdentityIsStableAndDeviceLocal() {
        let keychain = MemoryAppleKeychainStore()
        let store = DeviceIdentityKeychainStore(
            service: "at.oncloud.encryptedmemories.device.tests-\(UUID().uuidString)",
            account: "installation",
            keychain: keychain
        )
        defer { store.clear() }

        let first = store.loadOrCreate()
        #expect(!first.isEmpty)
        #expect(store.loadOrCreate() == first)
    }

    @Test func deviceIdentityReturnsEphemeralUUIDWhenKeychainFails() {
        let store = DeviceIdentityKeychainStore(
            service: "at.oncloud.encryptedmemories.device.tests", account: "installation",
            keychain: FailingAppleKeychainStore()
        )
        let first = store.loadOrCreate()
        let second = store.loadOrCreate()
        #expect(UUID(uuidString: first) != nil)
        #expect(UUID(uuidString: second) != nil)
        #expect(first != second)
    }

    @Test func fullPurgeCompletesMarkerOnlyAfterFilesAndKeychainSucceed() throws {
        let suite = "auth-purge-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("account.sqlite"))
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))

        let failed = ProtonAuthLocalDataPurge.perform(
            claim: claim, defaults: defaults, networkStores: networkStoreLocation(in: root)
        ) {
            throw AppleSecurityError(operation: .delete, status: errSecNotAvailable)
        }
        #expect(!failed)
        #expect(BackupLocalDataPurge.isPurgePending(defaults: defaults))

        let retry = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let succeeded = ProtonAuthLocalDataPurge.perform(
            claim: retry, defaults: defaults, networkStores: networkStoreLocation(in: root)
        ) {}
        #expect(succeeded)
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    @Test func pendingSignOutClaimSurvivesNetworkFailureAfterOtherCleanupCompletes() async throws {
        let suite = "auth-network-failed-claim-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let probe = StartupPurgeProbe()
        let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: claim, defaults: SendableUserDefaults(defaults),
            unusedNetworkStorePurge: {
                probe.record("network")
                return false
            },
            plaintextPurge: { true },
            purgeKeychain: { probe.record("keychain") }
        )
        #expect(!succeeded)
        #expect(probe.events == ["network", "keychain"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(BackupLocalDataPurge.isPurgePending(defaults: defaults))

        let retry = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        #expect(
            await ProtonAuthLocalDataPurge.performOffMain(
                claim: retry, defaults: SendableUserDefaults(defaults), networkStores: networkStoreLocation(in: root),
                purgeKeychain: {}))
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    @Test func unreadableAccountRootFailsTheSharedTransactionAfterOtherComponentsRun() async throws {
        let fm = FileManager.default
        let suite = "auth-account-metadata-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sandbox = fm.temporaryDirectory.appendingPathComponent("auth-account-metadata-\(UUID().uuidString)")
        let parent = sandbox.appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = parent.appendingPathComponent("EncryptedMemories", isDirectory: true)
        let otherRoot = sandbox.appendingPathComponent("Library/Caches/EncryptedMemories", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("account.sqlite"))
        let permissions = try #require(fm.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)
        defer {
            do {
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: parent.path)
            } catch {
                Issue.record("Could not restore the owned transaction permission fixture")
            }
            defaults.removePersistentDomain(forName: suite)
            do {
                try fm.removeItem(at: sandbox)
            } catch {
                Issue.record("Could not remove the restored UUID transaction fixture")
            }
        }
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root, otherRoot]))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        do {
            _ = try fm.attributesOfItem(atPath: root.path)
            Issue.record("Transaction fixture did not cause the required metadata permission error")
            return
        } catch {
            guard let error = error as? CocoaError, error.code == .fileReadNoPermission else {
                Issue.record("Transaction fixture caused an unexpected metadata error")
                return
            }
            print("605 aggregate PRE probe: verified non-missing CocoaError.fileReadNoPermission")
        }
        let probe = StartupPurgeProbe()

        let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: claim, defaults: SendableUserDefaults(defaults),
            unusedNetworkStorePurge: {
                probe.record("network")
                return true
            },
            plaintextPurge: {
                probe.record("plaintext")
                return true
            },
            purgeKeychain: { probe.record("keychain") })
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: parent.path)

        #expect(!succeeded)
        #expect(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        #expect(probe.events == ["network", "plaintext", "keychain"])
        #expect(try Data(contentsOf: root.appendingPathComponent("account.sqlite")) == Data([1]))
        do {
            _ = try fm.attributesOfItem(atPath: otherRoot.path)
            Issue.record("The other account root must be positively absent")
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
        }
    }

    @Test func signOutCannotSucceedWithoutAResolvedNetworkStoreLocation() async throws {
        let suite = "auth-network-unresolved-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let probe = ThreadProbe()
        let succeeded = await ProtonAuthLocalDataPurge.performOffMain(
            claim: claim, defaults: SendableUserDefaults(defaults), networkStores: nil,
            purgeKeychain: { probe.recordCurrentThread() }
        )
        #expect(!succeeded)
        #expect(probe.wasMainThread != nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    @Test func refusedSignOutLocationsClearOldCompletionAndRetainClaim() async throws {
        var refusals = ["unresolved", "foreignCaches"]
        #if os(macOS)
            refusals.append("foreignSandbox")
        #endif
        for refusal in refusals {
            let suite = "auth-network-refused-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let accountRoot = root.appendingPathComponent("account", isDirectory: true)
            try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
            let library = root.appendingPathComponent(
                "Containers/\(refusal == "foreignSandbox" ? "other.id" : "at.oncloud.encryptedmemories")/Data/Library",
                isDirectory: true)
            let caches =
                refusal == "foreignCaches"
                ? root.appendingPathComponent("foreign/Caches", isDirectory: true)
                : library.appendingPathComponent("Caches", isDirectory: true)
            let victim = caches.appendingPathComponent("at.oncloud.encryptedmemories/Cache.db")
            try FileManager.default.createDirectory(
                at: victim.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: victim)
            BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
            defaults.set(true, forKey: UnusedNetworkStorePurge.completedKey)
            let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [accountRoot]))
            let probe = StartupPurgeProbe()
            let succeeded = await ProtonAuthLocalDataPurge.performOffMain(
                claim: claim, defaults: SendableUserDefaults(defaults),
                networkStores: refusal == "unresolved"
                    ? nil
                    : UnusedNetworkStorePurge.Location(
                        libraryDirectory: library, cachesDirectory: caches,
                        bundleIdentifier: "at.oncloud.encryptedmemories"),
                purgeKeychain: { probe.record("keychain") })
            #expect(!succeeded)
            #expect(
                !defaults.bool(forKey: UnusedNetworkStorePurge.completedKey),
                "refused location must clear old flag: \(refusal)")
            #expect(BackupLocalDataPurge.isPurgePending(defaults: defaults))
            #expect(probe.events == ["keychain"])
            #expect(!FileManager.default.fileExists(atPath: accountRoot.path))
            #expect(try Data(contentsOf: victim) == Data([1]))
        }
    }

    @Test(arguments: [false, true])
    func keychainPurgeAttemptsBothServicesAndRetainsTheFirstError(secondFails: Bool) throws {
        let keychain = RecordingPurgeKeychainStore(secondFails: secondFails)
        #expect(throws: AppleSecurityError(operation: .delete, status: errSecNotAvailable)) {
            try ProtonAuthLocalDataPurge.purgeKeychain(using: keychain)
        }
        #expect(keychain.services == [SessionKeychainStore.defaultService, DeviceIdentityKeychainStore.defaultService])
    }

    @Test func noClaimStartupWithUnresolvedLocationPreservesTheCompletedFlag() async throws {
        let suite = "auth-no-claim-unresolved-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UnusedNetworkStorePurge.completedKey)
        let probe = StartupPurgeProbe()
        let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: nil, defaults: defaults, plaintextPurgeSucceeded: true, networkStores: nil,
            purgeKeychain: { probe.record("keychain") })
        #expect(succeeded)
        #expect(defaults.bool(forKey: UnusedNetworkStorePurge.completedKey))
        #expect(probe.events.isEmpty)
    }

    @Test func settingsResetRemovesSessionIdentityAndCachesBeforeBootstrap() async throws {
        let suite = "settings-reset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["library.sqlite", "ml.sqlite", "thumbnail.cache", "model.artifact"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let keychain = MemoryAppleKeychainStore()
        let store = SessionKeychainStore(
            service: SessionKeychainStore.defaultService, account: "default", keychain: keychain)
        try store.save(ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"))
        let identity = DeviceIdentityKeychainStore(
            service: DeviceIdentityKeychainStore.defaultService, account: "installation", keychain: keychain)
        let oldIdentity = identity.loadOrCreate()
        defaults.set(true, forKey: BackupLocalDataPurge.resetOnNextLaunchKey)
        #expect(BackupLocalDataPurge.prepareRequestedResetForLaunch(defaults: defaults, persistentDomainName: suite))
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        #expect(
            await ProtonAuthLocalDataPurge.performStartupOffMain(
                claim: claim, defaults: SendableUserDefaults(defaults), unusedNetworkStorePurge: { true },
                plaintextPurge: { true },
                purgeKeychain: { try ProtonAuthLocalDataPurge.purgeKeychain(using: keychain) }
            ))
        #expect(try store.load() == nil)
        #expect(identity.loadOrCreate() != oldIdentity)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
        #expect(!defaults.bool(forKey: BackupLocalDataPurge.resetOnNextLaunchKey))
    }

    @Test @MainActor func awaitedPurgeLeavesTheUIExecutor() async throws {
        let suite = "auth-purge-off-main-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-purge-off-main-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("account.sqlite"))
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let probe = ThreadProbe()

        let succeeded = await ProtonAuthLocalDataPurge.performOffMain(
            claim: claim,
            defaults: SendableUserDefaults(defaults),
            networkStores: networkStoreLocation(in: root)
        ) {
            probe.recordCurrentThread()
        }

        #expect(succeeded)
        #expect(probe.wasMainThread == false)
    }

    @Test @MainActor func startupCleanupRunsInOrderOffMainAndWaitsForAccountPurge() async throws {
        let suite = "auth-startup-purge-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-startup-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("account.sqlite"))
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let probe = StartupPurgeProbe()

        let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: claim,
            defaults: SendableUserDefaults(defaults),
            unusedNetworkStorePurge: { true },
            plaintextPurge: {
                probe.record("plaintext")
                return true
            },
            purgeKeychain: {
                probe.record("keychain")
            }
        )

        #expect(succeeded)
        #expect(probe.events == ["plaintext", "keychain"])
        #expect(probe.usedMainThread == false)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    /// Drives the internal startup overload that builds the purge closure, with an injected store location,
    /// so an unhooked purge fails here. The public wrapper (`Location.current`, `.standard`) is not exercised.
    @Test func productionStartupCleanupRemovesTheUnusedNetworkStores() async throws {
        let suite = "auth-startup-network-wiring-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-startup-network-wiring-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bundleIdentifier = "at.oncloud.encryptedmemories"
        let library = root.appendingPathComponent("Containers/\(bundleIdentifier)/Data/Library", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        let urlCache = caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let compileCache = urlCache.appendingPathComponent("com.apple.e5rt.e5bundlecache/entry")
        let cookieFile = library.appendingPathComponent("Cookies/Cookies.binarycookies")
        for file in [urlCache.appendingPathComponent("Cache.db"), compileCache, cookieFile] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }

        let probe = StartupPurgeProbe()
        let location = UnusedNetworkStorePurge.Location(
            libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier)
        let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: nil,
            defaults: defaults,
            plaintextPurgeSucceeded: true,
            networkStores: location,
            purgeKeychain: { probe.record("keychain") }
        )

        #expect(succeeded)
        #expect(!FileManager.default.fileExists(atPath: urlCache.appendingPathComponent("Cache.db").path))
        #expect(!FileManager.default.fileExists(atPath: cookieFile.path))
        #expect(FileManager.default.fileExists(atPath: compileCache.path))
        #expect(defaults.bool(forKey: UnusedNetworkStorePurge.completedKey))

        for file in [urlCache.appendingPathComponent("Cache.db"), cookieFile] {
            try Data([2]).write(to: file)
        }
        #expect(
            await ProtonAuthLocalDataPurge.performStartupOffMain(
                claim: nil, defaults: defaults, plaintextPurgeSucceeded: true, networkStores: location,
                purgeKeychain: { probe.record("keychain") }))
        #expect(try Data(contentsOf: urlCache.appendingPathComponent("Cache.db")) == Data([2]))
        #expect(try Data(contentsOf: cookieFile) == Data([2]))
        #expect(try Data(contentsOf: compileCache) == Data([1]))
        #expect(probe.events.isEmpty)
    }

    #if os(macOS)
        @Test func pendingStartupCompositionPurgesResidualsDespiteACompletedFlag() async throws {
            let suite = "auth-pending-startup-network-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let bundleIdentifier = "at.oncloud.encryptedmemories"
            let library = root.appendingPathComponent("Containers/\(bundleIdentifier)/Data/Library", isDirectory: true)
            let caches = library.appendingPathComponent("Caches", isDirectory: true)
            let networkCache = caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
            let residuals =
                ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/entry"]
                .map { networkCache.appendingPathComponent($0) }
                + [library.appendingPathComponent("Cookies/Cookies.binarycookies")]
            let protected = [
                networkCache.appendingPathComponent("com.apple.e5rt.e5bundlecache/compiled.bin"),
                caches.appendingPathComponent("EncryptedMemories/protected.cache"),
            ]
            let accountRoot = library.appendingPathComponent("Application Support/EncryptedMemories", isDirectory: true)
            for file in residuals + protected + [accountRoot.appendingPathComponent("account.sqlite")] {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: file)
            }
            BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
            defaults.set(true, forKey: UnusedNetworkStorePurge.completedKey)
            let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [accountRoot]))
            let probe = StartupPurgeProbe()
            let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
                claim: claim, defaults: defaults, plaintextPurgeSucceeded: true,
                networkStores: UnusedNetworkStorePurge.Location(
                    libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier),
                purgeKeychain: { probe.record("keychain") }
            )
            #expect(succeeded)
            for file in residuals { #expect(!FileManager.default.fileExists(atPath: file.path)) }
            for file in protected { #expect(try Data(contentsOf: file) == Data([1])) }
            #expect(probe.events == ["keychain"])
            #expect(!probe.usedMainThread)
            #expect(!FileManager.default.fileExists(atPath: accountRoot.path))
            #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
        }

    #endif

    @Test func signOutRemovesNetworkStoresLeftByFailedStartupCleanup() async throws {
        let suite = "auth-signout-network-residual-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-signout-network-residual-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bundleIdentifier = "at.oncloud.encryptedmemories"
        let library = root.appendingPathComponent("Containers/\(bundleIdentifier)/Data/Library", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        let networkCache = caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let residuals =
            ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/entry"]
            .map { networkCache.appendingPathComponent($0) }
            + [library.appendingPathComponent("Cookies/Cookies.binarycookies")]
        let protected = [
            networkCache.appendingPathComponent("com.apple.e5rt.e5bundlecache/compiled.bin"),
            networkCache.appendingPathComponent("Cache.db.keep"),
            caches.appendingPathComponent("EncryptedMemories/protected.cache"),
            library.appendingPathComponent("Cookies/Other.binarycookies"),
        ]
        let accountRoot = library.appendingPathComponent("Application Support/EncryptedMemories", isDirectory: true)
        let accountFile = accountRoot.appendingPathComponent("account.sqlite")
        for file in residuals + protected + [accountFile] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        let sendableDefaults = SendableUserDefaults(defaults)
        let startupSucceeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: nil, defaults: sendableDefaults,
            unusedNetworkStorePurge: {
                UnusedNetworkStorePurge.purgeOnce(
                    defaults: sendableDefaults.value, libraryDirectory: library,
                    cachesDirectory: caches, bundleIdentifier: bundleIdentifier,
                    removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
                )?.succeeded == true
            },
            plaintextPurge: { true }, purgeKeychain: {}
        )
        try #require(startupSucceeded)
        #expect(!defaults.bool(forKey: UnusedNetworkStorePurge.completedKey))
        for file in residuals {
            try #require(FileManager.default.fileExists(atPath: file.path))
        }

        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults, persistentDomainName: suite)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [accountRoot]))
        let succeeded = await ProtonAuthLocalDataPurge.performOffMain(
            claim: claim, defaults: sendableDefaults,
            networkStores: UnusedNetworkStorePurge.Location(
                libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier),
            purgeKeychain: {}
        )

        #expect(succeeded)
        for file in residuals {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        for file in protected {
            #expect(try Data(contentsOf: file) == Data([1]))
        }
        #expect(!FileManager.default.fileExists(atPath: accountRoot.path))
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    @Test @MainActor func startupCleanupRemovesUnusedNetworkStoresFirstAndOffMain() async throws {
        let suite = "auth-startup-network-store-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = StartupPurgeProbe()

        let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: nil,
            defaults: SendableUserDefaults(defaults),
            unusedNetworkStorePurge: {
                probe.record("network")
                return true
            },
            plaintextPurge: {
                probe.record("plaintext")
                return true
            },
            purgeKeychain: {
                probe.record("keychain")
            }
        )

        #expect(succeeded)
        #expect(probe.events == ["network", "plaintext"])
        #expect(probe.usedMainThread == false)
    }
}

private struct NonPersistingAppleKeychainStore: AppleKeychainStoring {
    func data(for item: AppleKeychainItem) throws -> Data? { nil }
    func setData(_ data: Data, for item: AppleKeychainItem) throws {}
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data { data }
    func removeData(for item: AppleKeychainItem) throws {}
    func removeAllData(service: String) throws {}
}

private struct FailingAppleKeychainStore: AppleKeychainStoring {
    func data(for item: AppleKeychainItem) throws -> Data? {
        throw AppleSecurityError(operation: .read, status: errSecNotAvailable)
    }
    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        throw AppleSecurityError(operation: .add, status: errSecNotAvailable)
    }
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        throw AppleSecurityError(operation: .add, status: errSecNotAvailable)
    }
    func removeData(for item: AppleKeychainItem) throws {
        throw AppleSecurityError(operation: .delete, status: errSecNotAvailable)
    }
    func removeAllData(service: String) throws {
        throw AppleSecurityError(operation: .delete, status: errSecNotAvailable)
    }
}

private final class MemoryAppleKeychainStore: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppleKeychainItem: Data] = [:]

    func data(for item: AppleKeychainItem) throws -> Data? {
        lock.withLock { storage[item] }
    }

    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        lock.withLock { storage[item] = data }
    }

    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        lock.withLock {
            if let existing = storage[item] { return existing }
            storage[item] = data
            return data
        }
    }

    func removeData(for item: AppleKeychainItem) throws {
        lock.withLock { _ = storage.removeValue(forKey: item) }
    }

    func removeAllData(service: String) throws {
        lock.withLock { storage = storage.filter { $0.key.service != service } }
    }
}

private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var wasMainThread: Bool? { lock.withLock { value } }

    func recordCurrentThread() {
        lock.withLock { value = Thread.isMainThread }
    }
}

private final class StartupPurgeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedMainThread = false

    var events: [String] { lock.withLock { recordedEvents } }
    var usedMainThread: Bool { lock.withLock { recordedMainThread } }

    func record(_ event: String) {
        lock.withLock {
            recordedEvents.append(event)
            recordedMainThread = recordedMainThread || Thread.isMainThread
        }
    }
}

private final class RecordingPurgeKeychainStore: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedServices: [String] = []
    private let secondFails: Bool

    init(secondFails: Bool) { self.secondFails = secondFails }
    var services: [String] { lock.withLock { recordedServices } }
    func data(for item: AppleKeychainItem) throws -> Data? { nil }
    func setData(_ data: Data, for item: AppleKeychainItem) throws {}
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data { data }
    func removeData(for item: AppleKeychainItem) throws {}
    func removeAllData(service: String) throws {
        let count = lock.withLock {
            recordedServices.append(service)
            return recordedServices.count
        }
        if count == 1 { throw AppleSecurityError(operation: .delete, status: errSecNotAvailable) }
        if secondFails { throw AppleSecurityError(operation: .delete, status: errSecAuthFailed) }
    }
}
