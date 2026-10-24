import AppleSecurityCore
import Foundation
import PhotosCore

/// A fully-authenticated Proton session obtained via the web-link (session fork) flow.
public struct ProtonSession: Codable, Sendable, Equatable {
    public let uid: String
    public var accessToken: String
    public var refreshToken: String
    /// Mailbox/key password (decrypted from the fork payload). Unlocks the user's PGP keys.
    public let keyPassword: String

    public init(uid: String, accessToken: String, refreshToken: String, keyPassword: String) {
        self.uid = uid
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.keyPassword = keyPassword
    }
}

/// Persists the session (tokens + key password) in the platform Keychain.
public struct SessionKeychainStore: Sendable {
    private let item: AppleKeychainItem
    private let keychain: any AppleKeychainStoring

    public init(service: String = Self.defaultService, account: String = "default") {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST && os(macOS)
            self.init(service: service, account: account, keychain: UpgradeTestSessionFile())
        #else
            self.init(service: service, account: account, keychain: SystemAppleKeychainStore())
        #endif
    }

    public init(service: String, account: String, keychain: any AppleKeychainStoring) {
        self.item = AppleKeychainItem(
            service: service,
            account: account,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        self.keychain = keychain
    }

    private static let productionService = "at.oncloud.encryptedmemories.session"
    #if ENCRYPTED_MEMORIES_UPGRADE_TEST
        public static let defaultService = productionService + ".upgrade-test"
    #else
        public static let defaultService = productionService
    #endif

    public func load() throws -> ProtonSession? {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            guard UpgradeTestProbe.isRequested else { throw SessionKeychainError.invalidPayload }
            UpgradeTestProbe.rejectExternalNetwork()
            let seedIdentity = [
                "server": UpgradeTestProbe.endpoint.absoluteString,
                "account": UpgradeTestProbe.accountUID,
            ]
            if UpgradeTestProbe.seedsAccount,
                UserDefaults.standard.dictionary(forKey: "upgrade.fixture.seeded") as? [String: String] != seedIdentity
            {
                guard let domain = Bundle.main.bundleIdentifier, domain.hasSuffix(".upgrade-test") else {
                    throw SessionKeychainError.invalidPayload
                }
                UserDefaults.standard.removePersistentDomain(forName: domain)
                try clear()
                try save(
                    ProtonSession(
                        uid: UpgradeTestProbe.accountUID, accessToken: "synthetic-access",
                        refreshToken: "synthetic-refresh", keyPassword: "synthetic-key"))
                UserDefaults.standard.set(seedIdentity, forKey: "upgrade.fixture.seeded")
            }
        #endif
        guard let data = try keychain.data(for: item) else { return nil }
        do {
            let session = try JSONDecoder().decode(ProtonSession.self, from: data)
            #if ENCRYPTED_MEMORIES_UPGRADE_TEST
                guard session.uid == UpgradeTestProbe.accountUID else { throw SessionKeychainError.invalidPayload }
                UpgradeTestProbe.checkpoint("session.loaded")
            #endif
            return session
        } catch {
            throw SessionKeychainError.invalidPayload
        }
    }

    public func save(_ session: ProtonSession) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.setData(data, for: item)
        guard try keychain.data(for: item) == data else {
            throw SessionKeychainError.verificationFailed
        }
    }

    public func clear() throws {
        try keychain.removeData(for: item)
    }
}

public enum SessionKeychainError: Error, LocalizedError, Sendable, Equatable {
    case invalidPayload
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            L10n.string("auth.saved_session_invalid")
        case .verificationFailed:
            L10n.string("auth.saved_session_verification_failed")
        }
    }
}

/// Full app-private Keychain reset shared by macOS, iOS and iPadOS.
public enum ProtonAuthLocalDataPurge {
    /// Performs the shared file + Keychain transaction. The durable request is completed only when
    /// both halves succeed, so an interrupted or partially-failed logout is retried before the next
    /// session can open account-owned stores.
    @discardableResult
    public static func perform(
        claim: BackupLocalDataPurge.Claim,
        defaults: UserDefaults = .standard
    ) -> Bool {
        perform(claim: claim, defaults: defaults, networkStores: .current) {
            try purgeKeychain()
        }
    }

    /// Runs the same ordered purge away from the UI executor. The caller still awaits completion, so a
    /// new account cannot open stores while deletion is in flight.
    @discardableResult
    public static func performOffMain(
        claim: BackupLocalDataPurge.Claim,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        await performOffMain(claim: claim, defaults: SendableUserDefaults(defaults), networkStores: .current) {
            try purgeKeychain()
        }
    }

    /// Runs all cold-start cleanup in one ordered utility task. The caller still awaits the task, so
    /// session bootstrap cannot open account stores while either purge is in flight.
    @discardableResult
    public static func performStartupOffMain(
        claim: BackupLocalDataPurge.Claim?,
        defaults: UserDefaults = .standard,
        plaintextPurgeSucceeded: Bool? = nil
    ) async -> Bool {
        await performStartupOffMain(
            claim: claim,
            defaults: defaults,
            plaintextPurgeSucceeded: plaintextPurgeSucceeded,
            networkStores: UnusedNetworkStorePurge.Location.current,
            purgeKeychain: { try purgeKeychain() }
        )
    }

    static func performStartupOffMain(
        claim: BackupLocalDataPurge.Claim?,
        defaults: UserDefaults,
        plaintextPurgeSucceeded: Bool?,
        networkStores: UnusedNetworkStorePurge.Location?,
        purgeKeychain: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        #if os(iOS)
            if claim != nil {
                // Foundation's default network stores are app-sandbox local on iOS, but live
                // outside our product cache roots. Await their reset before any session opens.
                await withCheckedContinuation { continuation in
                    URLSession.shared.reset { continuation.resume() }
                }
            }
        #endif
        let sendableDefaults = SendableUserDefaults(defaults)
        return await performStartupOffMain(
            claim: claim,
            defaults: sendableDefaults,
            unusedNetworkStorePurge: {
                if claim != nil {
                    return UnusedNetworkStorePurge.purgeForSignOut(
                        defaults: sendableDefaults.value, location: networkStores)?
                        .succeeded == true
                }
                UnusedNetworkStorePurge.purgeOnce(defaults: sendableDefaults.value, location: networkStores)
                return true
            },
            plaintextPurge: {
                if let plaintextPurgeSucceeded {
                    return plaintextPurgeSucceeded
                }
                return TransientPlaintextPurge.purgeShareExports().succeeded
            },
            purgeKeychain: purgeKeychain
        )
    }

    static func performOffMain(
        claim: BackupLocalDataPurge.Claim,
        defaults: SendableUserDefaults,
        networkStores: UnusedNetworkStorePurge.Location?,
        purgeKeychain: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        return await Task.detached(priority: .utility) {
            perform(claim: claim, defaults: defaults.value, networkStores: networkStores, purgeKeychain: purgeKeychain)
        }.value
    }

    /// Startup without a sign-out claim keeps network cleanup best effort and once per arming.
    /// A pending sign-out claim requires verified network cleanup before the transaction can complete.
    /// Each run is awaited before an account opens.
    static func performStartupOffMain(
        claim: BackupLocalDataPurge.Claim?,
        defaults: SendableUserDefaults,
        unusedNetworkStorePurge: @escaping @Sendable () -> Bool,
        plaintextPurge: @escaping @Sendable () -> Bool,
        purgeKeychain: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let networkStoresPurged = unusedNetworkStorePurge()
            let plaintextPurgeSucceeded = plaintextPurge()
            let signOutPurgeSucceeded =
                claim.map {
                    perform(
                        claim: $0, defaults: defaults.value,
                        unusedNetworkStorePurge: { networkStoresPurged }, purgeKeychain: purgeKeychain)
                } ?? true
            return plaintextPurgeSucceeded && signOutPurgeSucceeded
        }.value
    }

    static func perform(
        claim: BackupLocalDataPurge.Claim,
        defaults: UserDefaults,
        networkStores: UnusedNetworkStorePurge.Location?,
        purgeKeychain: () throws -> Void
    ) -> Bool {
        perform(
            claim: claim, defaults: defaults,
            unusedNetworkStorePurge: {
                UnusedNetworkStorePurge.purgeForSignOut(defaults: defaults, location: networkStores)?.succeeded == true
            },
            purgeKeychain: purgeKeychain)
    }

    private static func perform(
        claim: BackupLocalDataPurge.Claim,
        defaults: UserDefaults,
        unusedNetworkStorePurge: () -> Bool,
        purgeKeychain: () throws -> Void
    ) -> Bool {
        let fileResult = claim.perform(defaults: defaults, completesRequestOnSuccess: false)
        let networkStoresPurged = unusedNetworkStorePurge()
        let keychainPurged: Bool
        do {
            try purgeKeychain()
            keychainPurged = true
        } catch {
            keychainPurged = false
        }
        guard fileResult.succeeded, networkStoresPurged, keychainPurged else { return false }
        BackupLocalDataPurge.markPurgeCompleted(defaults: defaults)
        return true
    }

    public static func purgeKeychain() throws {
        try purgeKeychain(using: SystemAppleKeychainStore())
    }

    static func purgeKeychain(using keychain: any AppleKeychainStoring) throws {
        let services = [
            SessionKeychainStore.defaultService,
            DeviceIdentityKeychainStore.defaultService,
        ]
        var firstError: (any Error)?
        for service in services {
            do {
                try keychain.removeAllData(service: service)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

/// Foundation documents `UserDefaults` access as thread-safe, but the type is not annotated Sendable.
/// Keep the unchecked boundary private and transport only an immutable reference into the purge task.
struct SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}
