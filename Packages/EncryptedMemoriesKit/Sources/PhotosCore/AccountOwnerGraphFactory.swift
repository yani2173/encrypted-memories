import Foundation

/// Builds the account owner graph while native adapters retain their concrete owners and presentation rules.
@MainActor public enum AccountOwnerGraphFactory {
    public typealias Shutdown = @MainActor @Sendable () async throws -> Void

    public enum Profile: CaseIterable, Equatable, Sendable {
        case mobileRetry
        case mobileSignOut
        case macSignOut
        case macScopeRecovery
    }

    /// Keeps one snapshot across cancellation: callbacks can clear the live slots, so never read them again.
    /// Cancellation may attach the shutdown tasks that the retained owners must subsequently join.
    public static func captureAndCancel<Owners>(
        _ capture: () -> Owners, cancel: (inout Owners) -> Void
    ) -> Owners {
        var owners = capture()
        cancel(&owners)
        return owners
    }

    /// Nil stage operations omit a stage; adapters over absent concrete owners remain registered no-ops.
    /// Nil pending-close operations skip only that close, never photo backup.
    /// All three photo-stage steps run in order, even after an error; the first error is rethrown after store close.
    public static func makeCoordinator(
        profile: Profile,
        platformTasks: @escaping Shutdown,
        smartSearch: @escaping Shutdown,
        locationCrawl: Shutdown?,
        folderBackup: Shutdown?,
        closePendingSession: Shutdown?,
        photoBackup: @escaping Shutdown,
        closePendingStore: Shutdown?,
        albumSync: @escaping Shutdown,
        facade: @escaping Shutdown,
        caches: Shutdown?,
        logs: Shutdown?,
        purge: Shutdown?
    ) throws -> AccountTeardownCoordinator {
        var owners: [AccountTeardownOwner] = []
        func append(_ stage: AccountTeardownStage, _ shutdown: Shutdown?) {
            guard let shutdown else { return }
            owners.append(
                AccountTeardownOwner(id: id(profile: profile, stage: stage), stage: stage, shutdown: shutdown))
        }
        append(.platformTasks, platformTasks)
        append(.smartSearch, smartSearch)
        append(.locationCrawl, locationCrawl)
        append(.folderBackup, folderBackup)
        append(.photoBackup) {
            // RetiredPendingGrid.close skips its hooks for an empty pair, which would skip a live photo backup.
            try await shutdownPhotoBackup(
                closePendingSession: closePendingSession, photoBackup: photoBackup,
                closePendingStore: closePendingStore)
        }
        append(.albumSync, albumSync)
        append(.facade, facade)
        append(.caches, caches)
        append(.logs, logs)
        append(.purgeClaims, purge)
        return try AccountTeardownCoordinator(owners: owners)
    }

    static func shutdownPhotoBackup(
        closePendingSession: Shutdown?, photoBackup: @escaping Shutdown, closePendingStore: Shutdown?
    ) async throws {
        var firstError: (any Error)?
        for shutdown in [closePendingSession, photoBackup, closePendingStore] {
            do {
                try await shutdown?()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func id(profile: Profile, stage: AccountTeardownStage) -> String {
        if profile == .mobileRetry { return "mobile.retry." + suffix(stage) }
        if profile == .macScopeRecovery {
            let name: String
            switch stage {
            case .platformTasks: name = "platform"
            case .purgeClaims: name = "account-data"
            default: name = suffix(stage)
            }
            return "mac.scope-recovery." + name
        }
        let mobile = profile == .mobileSignOut
        switch stage {
        case .platformTasks: return mobile ? "mobile.platform-tasks" : "mac.platform-build"
        case .smartSearch: return "shared.smart-search"
        case .locationCrawl: return mobile ? "mobile.location-crawl" : "mac.location-crawl"
        case .folderBackup: return mobile ? "mobile.folder-backup" : "mac.folder-backup"
        case .photoBackup: return "shared.photo-backup"
        case .albumSync: return "shared.album-sync"
        case .facade: return "shared.proton-facade"
        case .caches: return mobile ? "mobile.originals-cache" : "mac.offline-caches"
        case .logs: return "shared.debug-log"
        case .purgeClaims: return "shared.local-data-claim"
        }
    }

    private static func suffix(_ stage: AccountTeardownStage) -> String {
        switch stage {
        case .platformTasks: "platform-tasks"
        case .smartSearch: "smart-search"
        case .locationCrawl: "location-crawl"
        case .folderBackup: "folder-backup"
        case .photoBackup: "photo-backup"
        case .albumSync: "album-sync"
        case .facade: "facade"
        case .caches: "caches"
        case .logs: "logs"
        case .purgeClaims: "purge-claims"
        }
    }
}
