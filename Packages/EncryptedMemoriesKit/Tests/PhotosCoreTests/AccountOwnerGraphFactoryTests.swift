import Foundation
import Testing

@testable import PhotosCore

@Suite @MainActor struct AccountOwnerGraphFactoryTests {
    @Test(arguments: AccountOwnerGraphFactory.Profile.allCases)
    func preservesEachPlatformOwnerList(profile: AccountOwnerGraphFactory.Profile) async throws {
        let events = Events()
        let coordinator = try make(profile, events: events)

        let report = await coordinator.teardown()

        #expect(report.succeeded)
        #expect(report.completedOwnerIDs == expectedIDs(profile))
        #expect(Set(report.completedOwnerIDs).count == report.completedOwnerIDs.count)
        let expected =
            profile == .mobileRetry
            ? ["platform", "smart", "location", "pending", "photo", "store", "album", "facade"]
            : profile == .macScopeRecovery
                ? [
                    "platform", "offline-stop", "smart", "folder", "pending", "photo", "store", "album", "facade",
                    "cache", "log", "purge",
                ]
                : profile == .macSignOut
                    ? [
                        "platform", "smart", "location", "folder", "pending", "photo", "store", "album", "facade",
                        "cache", "log", "purge",
                    ]
                    : [
                        "platform", "smart", "location", "pending", "photo", "store", "album", "facade", "cache", "log",
                        "purge",
                    ]
        #expect(events.values == expected)
    }

    @Test func anAbsentMobileClaimOmitsOnlyThePurgeOwner() async throws {
        let events = Events()
        let coordinator = try make(.mobileSignOut, events: events, hasPurge: false)

        let report = await coordinator.teardown()

        #expect(report.completedOwnerIDs == Array(expectedIDs(.mobileSignOut).dropLast()))
        #expect(!events.values.contains("purge"))
        #expect(events.values.suffix(2) == ["cache", "log"])
    }

    @Test(arguments: [
        "mac.location-crawl", "mac.folder-backup", "mac.offline-caches", "shared.debug-log", "shared.local-data-claim",
    ])
    func nilOperationOmitsOnlyItsOwner(omitted: String) async throws {
        func operation(_ ownerID: String) -> AccountOwnerGraphFactory.Shutdown? {
            ownerID == omitted ? nil : { @MainActor @Sendable in }
        }
        let coordinator = try AccountOwnerGraphFactory.makeCoordinator(
            profile: .macSignOut, platformTasks: {}, smartSearch: {},
            locationCrawl: operation("mac.location-crawl"), folderBackup: operation("mac.folder-backup"),
            closePendingSession: nil, photoBackup: {}, closePendingStore: nil, albumSync: {}, facade: {},
            caches: operation("mac.offline-caches"), logs: operation("shared.debug-log"),
            purge: operation("shared.local-data-claim"))

        let report = await coordinator.teardown()

        #expect(report.succeeded)
        #expect(report.completedOwnerIDs == expectedIDs(.macSignOut).filter { $0 != omitted })
    }

    @Test func absentConcreteOwnersRemainRegisteredNoOps() async throws {
        let coordinator = try AccountOwnerGraphFactory.makeCoordinator(
            profile: .mobileRetry, platformTasks: {}, smartSearch: {}, locationCrawl: {}, folderBackup: nil,
            closePendingSession: {}, photoBackup: {}, closePendingStore: {}, albumSync: {}, facade: {},
            caches: nil, logs: nil, purge: nil)

        let report = await coordinator.teardown()

        #expect(report.succeeded)
        #expect(report.completedOwnerIDs == expectedIDs(.mobileRetry))
    }

    @Test func capturedOwnersSurviveCancellationThatClearsLiveSlots() {
        let events = Events()
        let firstOwner = Owner("first", events: events)
        let secondOwner = Owner("second", events: events)
        var first: Owner? = firstOwner
        var second: Owner? = secondOwner
        let firstID = ObjectIdentifier(firstOwner)
        let secondID = ObjectIdentifier(secondOwner)
        var captures = 0
        let owners = AccountOwnerGraphFactory.captureAndCancel(
            {
                captures += 1
                events.values.append("capture")
                return (first: first, second: second)
            },
            cancel: { snapshot in
                snapshot.first?.cancel()
                first = nil
                second = nil
                snapshot.second?.cancel()
            })

        #expect(captures == 1)
        #expect(owners.first.map(ObjectIdentifier.init) == firstID)
        #expect(owners.second.map(ObjectIdentifier.init) == secondID)
        owners.first?.join()
        owners.second?.join()
        #expect(events.values == ["capture", "cancel-first", "cancel-second", "join-first", "join-second"])
    }

    @Test func cancellationResultsRemainInTheCapturedSnapshot() async {
        let events = Events()
        let owners = AccountOwnerGraphFactory.captureAndCancel(
            {
                (shutdown: Optional<Task<Void, Never>>.none, marker: "captured")
            },
            cancel: { snapshot in
                snapshot.shutdown = Task { events.values.append("stopped") }
            })

        #expect(owners.shutdown != nil)
        #expect(owners.marker == "captured")
        await owners.shutdown?.value
        #expect(events.values == ["stopped"])
    }

    @Test func photoBackupAndAlbumSyncFinishBeforeFacadeStarts() async throws {
        let events = Events()
        let photo = Gate()
        let album = Gate()
        let coordinator = try AccountOwnerGraphFactory.makeCoordinator(
            profile: .mobileRetry, platformTasks: {}, smartSearch: {}, locationCrawl: {}, folderBackup: nil,
            closePendingSession: { @MainActor @Sendable in events.values.append("pending") },
            photoBackup: {
                events.values.append("photo-start")
                await photo.wait()
                events.values.append("photo-end")
            }, closePendingStore: { @MainActor @Sendable in events.values.append("store") },
            albumSync: {
                events.values.append("album-start")
                await album.wait()
                events.values.append("album-end")
            }, facade: { @MainActor @Sendable in events.values.append("facade") }, caches: nil, logs: nil, purge: nil)
        let task = Task { await coordinator.teardown() }

        #expect(await eventually { photo.entered })
        #expect(!events.values.contains("facade"))
        #expect(!events.values.contains("album-start"))
        #expect(!events.values.contains("store"))
        #expect(events.values.first == "pending")
        photo.release()
        #expect(await eventually { album.entered })
        #expect(!events.values.contains("facade"))
        #expect(events.values.suffix(3) == ["photo-end", "store", "album-start"])
        album.release()
        let report = await task.value

        #expect(report.succeeded)
        #expect(events.values.suffix(2) == ["album-end", "facade"])
    }

    @Test(arguments: AccountOwnerGraphFactory.Profile.allCases, [false, true])
    func livePhotoBackupFinishesWithPresentOrAbsentPendingOwners(
        profile: AccountOwnerGraphFactory.Profile, hasPendingPair: Bool
    ) async throws {
        let events = Events()
        let photo = Gate()
        let session: AccountOwnerGraphFactory.Shutdown? =
            hasPendingPair ? { @MainActor @Sendable in events.values.append("pending") } : nil
        let store: AccountOwnerGraphFactory.Shutdown? =
            hasPendingPair ? { @MainActor @Sendable in events.values.append("store") } : nil
        let folder: AccountOwnerGraphFactory.Shutdown? =
            profile == .macSignOut || profile == .macScopeRecovery
            ? { @MainActor @Sendable in events.values.append("folder") } : nil
        let coordinator = try AccountOwnerGraphFactory.makeCoordinator(
            profile: profile, platformTasks: {}, smartSearch: {}, locationCrawl: nil, folderBackup: folder,
            closePendingSession: session,
            photoBackup: {
                events.values.append("photo-start")
                await photo.wait()
                events.values.append("photo-end")
            }, closePendingStore: store, albumSync: {},
            facade: { @MainActor @Sendable in events.values.append("facade") }, caches: nil, logs: nil, purge: nil)
        var completed = false
        let task = Task {
            let report = await coordinator.teardown()
            completed = true
            return report
        }

        #expect(await eventually { photo.entered || completed })
        #expect(photo.entered)
        #expect(!completed)
        #expect(!events.values.contains("facade"))
        #expect(!events.values.contains("store"))
        let prefix = folder == nil ? [] : ["folder"]
        #expect(events.values == prefix + (hasPendingPair ? ["pending", "photo-start"] : ["photo-start"]))
        photo.release()
        let report = await task.value

        #expect(report.succeeded)
        #expect(
            events.values
                == prefix
                + (hasPendingPair
                    ? ["pending", "photo-start", "photo-end", "store", "facade"]
                    : ["photo-start", "photo-end", "facade"]))
    }

    @Test(arguments: [["session"], ["photo"], ["session", "photo"], ["store"], ["session", "photo", "store"]])
    func photoStageAttemptsEveryCloseAfterFailure(failing: [String]) async throws {
        let events = Events()
        let coordinator = try AccountOwnerGraphFactory.makeCoordinator(
            profile: .mobileSignOut, platformTasks: {}, smartSearch: {}, locationCrawl: nil, folderBackup: nil,
            closePendingSession: {
                events.values.append("session")
                if failing.contains("session") { throw Failure.expected }
            },
            photoBackup: {
                events.values.append("photo")
                if failing.contains("photo") { throw Failure.expected }
            },
            closePendingStore: {
                events.values.append("store")
                if failing.contains("store") { throw Failure.expected }
            }, albumSync: {}, facade: { events.values.append("facade") }, caches: nil, logs: nil,
            purge: { events.values.append("purge") })

        let report = await coordinator.teardown()

        #expect(events.values == ["session", "photo", "store", "facade", "purge"])
        #expect(report.failures == [.init(ownerID: "shared.photo-backup", stage: .photoBackup)])
        #expect(report.completedOwnerIDs.last == "shared.local-data-claim")
    }

    @Test(arguments: [["session"], ["photo"], ["session", "photo"], ["store"], ["session", "photo", "store"]])
    func photoStageRethrowsTheFirstErrorAfterClosingTheStore(failing: [String]) async {
        let events = Events()
        let first = PhotoShutdownFailure()
        let later = PhotoShutdownFailure()
        var caught: (any Error)?
        do {
            try await AccountOwnerGraphFactory.shutdownPhotoBackup(
                closePendingSession: {
                    events.values.append("session")
                    if failing.contains("session") { throw first }
                },
                photoBackup: {
                    events.values.append("photo")
                    if failing.contains("photo") { throw failing.first == "photo" ? first : later }
                },
                closePendingStore: {
                    events.values.append("store")
                    if failing.contains("store") { throw failing.first == "store" ? first : later }
                })
        } catch {
            caught = error
        }

        #expect(events.values == ["session", "photo", "store"])
        #expect(caught as? PhotoShutdownFailure === first)
    }

    @Test(arguments: [AccountOwnerGraphFactory.Profile.mobileSignOut, .macSignOut])
    func signOutPurgeRunsLastAfterAnEarlierFailure(profile: AccountOwnerGraphFactory.Profile) async throws {
        let events = Events()
        let coordinator = try make(profile, events: events, failSmartSearch: true)

        let report = await coordinator.teardown()

        #expect(events.values.suffix(3) == ["cache", "log", "purge"])
        #expect(report.completedOwnerIDs.last == "shared.local-data-claim")
        #expect(report.failures == [.init(ownerID: "shared.smart-search", stage: .smartSearch)])
    }

    @Test func aFailedPurgeIsReportedWithoutChangingItsOwnerID() async throws {
        let events = Events()
        let coordinator = try make(.macSignOut, events: events, failPurge: true)

        let report = await coordinator.teardown()

        #expect(events.values.last == "purge")
        #expect(report.failures == [.init(ownerID: "shared.local-data-claim", stage: .purgeClaims)])
        #expect(!report.succeeded)
    }

    private func make(
        _ profile: AccountOwnerGraphFactory.Profile, events: Events, hasPurge: Bool = true,
        failSmartSearch: Bool = false, failPurge: Bool = false
    ) throws -> AccountTeardownCoordinator {
        let retry = profile == .mobileRetry
        let scope = profile == .macScopeRecovery
        let mac = profile == .macSignOut || scope
        let location: AccountOwnerGraphFactory.Shutdown? =
            scope ? nil : { @MainActor @Sendable in events.values.append("location") }
        let folder: AccountOwnerGraphFactory.Shutdown? =
            mac ? { @MainActor @Sendable in events.values.append("folder") } : nil
        let caches: AccountOwnerGraphFactory.Shutdown? =
            retry ? nil : { @MainActor @Sendable in events.values.append("cache") }
        let logs: AccountOwnerGraphFactory.Shutdown? =
            retry ? nil : { @MainActor @Sendable in events.values.append("log") }
        let purge: AccountOwnerGraphFactory.Shutdown? =
            retry || !hasPurge
            ? nil
            : { @MainActor @Sendable in
                events.values.append("purge")
                if failPurge { throw Failure.expected }
            }
        return try AccountOwnerGraphFactory.makeCoordinator(
            profile: profile,
            platformTasks: {
                events.values.append("platform")
                if scope { events.values.append("offline-stop") }
            },
            smartSearch: {
                events.values.append("smart")
                if failSmartSearch { throw Failure.expected }
            }, locationCrawl: location, folderBackup: folder,
            closePendingSession: { @MainActor @Sendable in events.values.append("pending") },
            photoBackup: { @MainActor @Sendable in events.values.append("photo") },
            closePendingStore: { @MainActor @Sendable in events.values.append("store") },
            albumSync: { @MainActor @Sendable in events.values.append("album") },
            facade: { @MainActor @Sendable in events.values.append("facade") }, caches: caches, logs: logs, purge: purge
        )
    }

    private func expectedIDs(_ profile: AccountOwnerGraphFactory.Profile) -> [String] {
        switch profile {
        case .mobileRetry:
            [
                "mobile.retry.platform-tasks", "mobile.retry.smart-search", "mobile.retry.location-crawl",
                "mobile.retry.photo-backup", "mobile.retry.album-sync", "mobile.retry.facade",
            ]
        case .mobileSignOut:
            [
                "mobile.platform-tasks", "shared.smart-search", "mobile.location-crawl", "shared.photo-backup",
                "shared.album-sync", "shared.proton-facade", "mobile.originals-cache", "shared.debug-log",
                "shared.local-data-claim",
            ]
        case .macSignOut:
            [
                "mac.platform-build", "shared.smart-search", "mac.location-crawl", "mac.folder-backup",
                "shared.photo-backup",
                "shared.album-sync", "shared.proton-facade", "mac.offline-caches", "shared.debug-log",
                "shared.local-data-claim",
            ]
        case .macScopeRecovery:
            [
                "mac.scope-recovery.platform", "mac.scope-recovery.smart-search", "mac.scope-recovery.folder-backup",
                "mac.scope-recovery.photo-backup", "mac.scope-recovery.album-sync", "mac.scope-recovery.facade",
                "mac.scope-recovery.caches", "mac.scope-recovery.logs", "mac.scope-recovery.account-data",
            ]
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}

@MainActor private final class Events { var values: [String] = [] }
private enum Failure: Error { case expected }

@MainActor private final class Owner {
    let name: String
    let events: Events
    init(_ name: String, events: Events) {
        self.name = name
        self.events = events
    }
    func cancel() { events.values.append("cancel-" + name) }
    func join() { events.values.append("join-" + name) }
}

@MainActor private final class Gate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class PhotoShutdownFailure: Error {}
