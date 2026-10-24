import CryptoKit
import Foundation
import PhotosCore

/// Decides how a completed timeline enumeration is published and cached.
/// A changed event token keeps the usable inventory but forces a later validation pass.
struct TimelineLoadCommitDecision: Equatable {
    /// Token stored beside the inventory. Nil keeps a partially enriched result memory-only.
    let persistedValidationToken: String?
    /// Baseline given to the shared change monitor. An empty value forces the next successful probe to refresh.
    let monitorBaseline: String
}

enum TimelineLoadCommitPolicy {
    static func decide(
        startEventToken: String,
        endEventToken: String,
        enrichmentComplete: Bool
    ) -> TimelineLoadCommitDecision {
        guard enrichmentComplete else {
            return TimelineLoadCommitDecision(
                persistedValidationToken: nil,
                monitorBaseline: ""
            )
        }
        guard startEventToken == endEventToken else {
            return TimelineLoadCommitDecision(
                persistedValidationToken: startEventToken,
                monitorBaseline: startEventToken
            )
        }
        return TimelineLoadCommitDecision(
            persistedValidationToken: endEventToken,
            monitorBaseline: endEventToken
        )
    }
}

/// In-memory proof window used only after the server invalidates event history. The server exposes no
/// inventory snapshot marker, so one full listing can still lag the event cursor and must remain uncommitted.
struct TimelineContinuityRecoveryState: Sendable, Equatable {
    let cursor: String
    let inventoryFingerprint: String
    let firstObservedAt: ContinuousClock.Instant
    let qualifiedPassCount: Int
}

enum TimelineContinuityRecoveryDecision: Sendable, Equatable {
    case restartWindow
    case wait(TimelineContinuityRecoveryState)
    case ready
}

enum TimelineContinuityRecoveryPolicy {
    static let secondPassDelay: Duration = .seconds(12)
    static let finalPassDelay: Duration = .seconds(30)

    /// Early monitor retries still reseed the cheap event cursor, but they must not traverse the complete Photos
    /// listing until the next qualified sample time. A moved cursor is immediately eligible for a new window.
    static func isEligibleForFullInventory(
        previous: TimelineContinuityRecoveryState,
        candidateCursor: String,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard previous.cursor == candidateCursor else { return true }
        let requiredDelay = previous.qualifiedPassCount >= 2 ? finalPassDelay : secondPassDelay
        return previous.firstObservedAt.duration(to: now) >= requiredDelay
    }

    /// Requires three identical full listings over one quiet window. The first pass starts the window. A
    /// matching pass at 12 seconds qualifies the second sample. A later matching pass at 30 seconds qualifies
    /// the third. Cursor movement or a second continuity loss discards all prior samples.
    static func decide(
        previous: TimelineContinuityRecoveryState?,
        startCursor: String,
        endCursor: String,
        endRequiresAuthoritativeRefresh: Bool,
        inventoryFingerprint: String,
        now: ContinuousClock.Instant
    ) -> TimelineContinuityRecoveryDecision {
        guard !endRequiresAuthoritativeRefresh, startCursor == endCursor else {
            return .restartWindow
        }
        guard let previous,
            previous.cursor == startCursor,
            previous.inventoryFingerprint == inventoryFingerprint
        else {
            return .wait(
                TimelineContinuityRecoveryState(
                    cursor: startCursor,
                    inventoryFingerprint: inventoryFingerprint,
                    firstObservedAt: now,
                    qualifiedPassCount: 1
                ))
        }

        let elapsed = previous.firstObservedAt.duration(to: now)
        if previous.qualifiedPassCount >= 2, elapsed >= finalPassDelay {
            return .ready
        }
        if previous.qualifiedPassCount == 1, elapsed >= secondPassDelay {
            return .wait(
                TimelineContinuityRecoveryState(
                    cursor: previous.cursor,
                    inventoryFingerprint: previous.inventoryFingerprint,
                    firstObservedAt: previous.firstObservedAt,
                    qualifiedPassCount: 2
                ))
        }
        return .wait(previous)
    }
}

/// Stateful bridge seam for the complete continuity-recovery lifecycle. Production and tests use the same
/// eligibility, qualification, and persistence boundary, so a failed save cannot consume the recovery cursor.
struct TimelineContinuityPostInventoryProbe: Sendable, Equatable {
    let cursor: String
    let requiresAuthoritativeRefresh: Bool
}

struct TimelineContinuityQualification: Sendable, Equatable {
    let endCursor: String
    let recoveryQualified: Bool
}

final class TimelineContinuityRecoveryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: TimelineContinuityRecoveryState?

    var state: TimelineContinuityRecoveryState? {
        lock.withLock { storedState }
    }

    func reset() {
        lock.withLock { storedState = nil }
    }

    private func requireInventoryEligibility(
        cursor: String,
        now: ContinuousClock.Instant
    ) throws {
        let eligible = lock.withLock { () -> Bool in
            guard let state = storedState else { return true }
            guard state.cursor == cursor else {
                storedState = nil
                return true
            }
            return TimelineContinuityRecoveryPolicy.isEligibleForFullInventory(
                previous: state,
                candidateCursor: cursor,
                now: now
            )
        }
        guard eligible else {
            throw TimelineContinuityRecoveryPendingError()
        }
    }

    /// Checks the quiet-window schedule before it invokes the production Photos-list closure. Early monitor
    /// retries therefore perform only event probes and cannot traverse the complete inventory by accident.
    func fetchInventory<Entry>(
        cursor: String,
        now: ContinuousClock.Instant,
        fetch: () async throws -> [Entry]
    ) async throws -> [Entry] {
        try requireInventoryEligibility(cursor: cursor, now: now)
        return try await fetch()
    }

    /// Records one stable, authoritative inventory pass. A non-ready decision always remains uncommitted.
    func qualify(
        startCursor: String,
        inventoryFingerprint: String,
        now: ContinuousClock.Instant,
        postInventoryProbe: () async throws -> TimelineContinuityPostInventoryProbe
    ) async throws -> TimelineContinuityQualification {
        // A failed final save must cause a fresh inventory and a fresh post-list event probe on retry. Keep this
        // probe inside the same seam instead of reusing an earlier observation from the caller.
        let probe = try await postInventoryProbe()
        let ready = lock.withLock { () -> Bool in
            switch TimelineContinuityRecoveryPolicy.decide(
                previous: storedState,
                startCursor: startCursor,
                endCursor: probe.cursor,
                endRequiresAuthoritativeRefresh: probe.requiresAuthoritativeRefresh,
                inventoryFingerprint: inventoryFingerprint,
                now: now
            ) {
            case .restartWindow:
                storedState = nil
                return false
            case .wait(let nextState):
                storedState = nextState
                return false
            case .ready:
                return true
            }
        }
        guard ready else { throw TimelineContinuityRecoveryPendingError() }
        return TimelineContinuityQualification(endCursor: probe.cursor, recoveryQualified: true)
    }

    /// Runs the real inventory-and-token save boundary. A qualified recovery clears its memory-only proof only
    /// after persistence succeeds. A failed save keeps the proof and forces the monitor to retain its old cursor.
    func persist(
        recoveryQualified: Bool,
        save: () -> Bool
    ) throws -> Bool {
        let cacheSaved = save()
        guard
            TimelineContinuityPersistencePolicy.permitsMonitorAdvance(
                recoveryQualified: recoveryQualified,
                cacheSaved: cacheSaved
            )
        else {
            throw TimelineContinuityRecoveryPendingError()
        }
        if recoveryQualified {
            lock.withLock { storedState = nil }
        }
        return cacheSaved
    }
}

enum TimelineContinuityPersistencePolicy {
    /// Once the quiet window qualifies, only a successful atomic inventory-and-token save may advance the
    /// monitor. A failed save must retry the same qualified recovery instead of consuming its cursor in memory.
    static func permitsMonitorAdvance(recoveryQualified: Bool, cacheSaved: Bool) -> Bool {
        !recoveryQualified || cacheSaved
    }
}

enum TimelineContinuityInventoryFingerprint {
    /// Hash every Photos-list field used by the timeline. Canonical entry and tag order prevents harmless server
    /// page ordering from resetting the quiet window, while related-photo order remains significant.
    static func make(entries: [PhotosListEntry]) -> String {
        var hasher = SHA256()
        func feed(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0x1F]))
        }
        func feed(_ value: Double) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data([0x1F]))
        }

        for entry in entries.sorted(by: { lhs, rhs in
            if lhs.linkID != rhs.linkID { return lhs.linkID < rhs.linkID }
            return lhs.captureTime < rhs.captureTime
        }) {
            feed(entry.linkID)
            feed(entry.captureTime)
            feed(entry.tags.sorted().map(String.init).joined(separator: ","))
            for related in entry.relatedPhotos {
                feed(related.linkID)
            }
            hasher.update(data: Data([0x1E]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct TimelineContinuityRecoveryPendingError: LocalizedError, TimelineInventoryConvergenceError {
    var errorDescription: String? {
        "The Proton Photos inventory is still converging after its event history was reset."
    }
}

enum TimelineInventorySource: Equatable {
    case sdkCache
    case authoritativePhotosList
    /// The stored inventory with the local evidence applied. No listing runs (see `TimelineLocalRebuild`).
    case localStore
}

/// Versioned envelope for the event token paired with a persisted Photos inventory. A contract bump invalidates
/// only fast-path validation and forces one authoritative listing; the cached rows remain visible while it runs.
enum TimelineInventoryValidationTokenPolicy {
    private static let prefix = "photos-inventory-v2:"

    static func persistedToken(remoteEventToken: String) -> String {
        prefix + remoteEventToken
    }

    static func remoteEventToken(from persistedToken: String?) -> String? {
        guard let persistedToken else { return nil }
        guard persistedToken.hasPrefix(prefix) else { return persistedToken }
        return String(persistedToken.dropFirst(prefix.count))
    }
}

enum TimelineInventoryVisibilityError: LocalizedError, TimelineInventoryConvergenceError {
    case pendingUploadsNotVisible(Int)
    case remoteChangesNotVisible(Int)

    var errorDescription: String? {
        switch self {
        case .pendingUploadsNotVisible(let count):
            "The server listing has not exposed \(count) completed upload(s) yet."
        case .remoteChangesNotVisible(let count):
            "The server listing has not exposed \(count) remotely changed photo(s) yet."
        }
    }
}

/// Uses one complete metadata listing for cold or changed inventories. SDK enumeration is retained only
/// for unchanged inventories: SDK 0.25 otherwise resolves the photos root again for every timeline page
/// and needs separate tag listings afterward.
enum TimelineInventorySourcePolicy {
    static func decide(
        cachedEventToken: String?,
        currentEventToken: String,
        hasPendingLocalUploads: Bool,
        hasUnmaterializedLocalEvidence: Bool,
        canRebuildLocally: Bool = false
    ) -> TimelineInventorySource {
        if hasPendingLocalUploads || hasUnmaterializedLocalEvidence { return .authoritativePhotosList }
        guard let cachedEventToken, cachedEventToken == currentEventToken else { return .authoritativePhotosList }
        return canRebuildLocally ? .localStore : .sdkCache
    }
}

/// The files that the volume events since the cached listing made active or removed. The last event of a file wins.
struct TimelineRemoteEventChanges: Equatable {
    /// Photos-share files the next listing must contain.
    var active: Set<String> = []
    /// Files that were deleted or moved to the trash. The photos listing can still return them for a short time.
    var removed: Set<String> = []
}

/// Which changed files the photos listing must show before a load may commit. A related file, such as the original of
/// an edit, its edit data, or a Live Photo video, shows only through its main photo. When that main photo moves to the
/// trash, the server keeps the related file active and sends no event for it, yet no listing shows it again.
enum TimelineRemoteVisibilityRequirement {
    typealias Link = RemoteLinkVisibility

    /// The main photos whose state decides whether the listing must show the given related files.
    static func mainPhotoLinkIDs(of links: [String: Link]) -> Set<String> {
        Set(links.values.compactMap(\.mainPhotoLinkID))
    }

    /// The missing files that the listing must still show. A file that the server no longer returns or keeps in the
    /// trash never shows; a related file waits only while its main photo is active.
    static func awaited(
        _ missing: Set<String>, links: [String: Link], mainPhotos: [String: Link]
    ) -> Set<String> {
        missing.filter { id in
            guard let link = links[id], link.isActive else { return false }
            guard let main = link.mainPhotoLinkID else { return true }
            return mainPhotos[main]?.isActive == true
        }
    }
}

enum TimelineRemoteEventVisibilityPolicy {
    static func apply(
        _ events: [VolumeEventPage.Item],
        photosShareID: String,
        to changes: inout TimelineRemoteEventChanges
    ) {
        for event in events {
            let isFile = event.linkType == nil || event.linkType == 2
            if event.eventType == 0 || (isFile && event.linkState == 2) {
                changes.active.remove(event.linkID)
                changes.removed.insert(event.linkID)
            } else if event.contextShareID == photosShareID,
                event.linkState != 0,
                isFile,
                event.linkState == nil || event.linkState == 1
            {
                changes.active.insert(event.linkID)
                changes.removed.remove(event.linkID)
            }
        }
    }
}
