import Foundation
import PhotosCore

/// The two local revisions that the foreground change token carries behind the server's event cursor: the
/// published media-type evidence and the published order evidence.
struct TimelineLocalRevisions: Equatable, Sendable {
    let mediaType: Int
    let order: Int
}

/// What the last persisted timeline load of this backend was built from: the server event cursor of the listing (the
/// raw cursor, without the prefix of the stored validation token) and the local revisions that were current when its
/// sections were grouped.
struct TimelineLoadBasis: Equatable, Sendable {
    let eventToken: String
    let revisions: TimelineLocalRevisions
}

/// Rebuilds the timeline from the local store when only local evidence changed since the last load.
///
/// A media-type or order revision changes the foreground change token, although the server's event cursor is the
/// same. A load then enumerated the whole library again (SDK enumeration, three tag listings) to apply that local
/// evidence. The stored inventory is the result of the last load for that same cursor, so applying the evidence to it
/// gives the same sections without a listing. Every other situation keeps the existing sources.
enum TimelineLocalRebuild {
    /// The facts that decide whether the stored inventory can stand in for a listing.
    struct Conditions {
        let basis: TimelineLoadBasis?
        /// The raw server event cursor of this load.
        let currentEventToken: String
        let currentRevisions: TimelineLocalRevisions
        let hasPendingLocalUploads: Bool
        let hasUnmaterializedLocalEvidence: Bool
        let hasPhotosAwaitingLibrary: Bool
        /// A photo restored here waits to be listed by the library twice.
        let hasRestoredPhotos: Bool
        let continuityRecoveryRequired: Bool
    }

    /// The facts that need no store read. All of these must hold:
    /// - the last persisted load of this backend ran for the same server event cursor;
    /// - only a local revision differs from that load (a load with nothing changed keeps the existing source);
    /// - no upload, local evidence, trash wait, restore or continuity recovery needs a listing.
    static func passesConditions(_ conditions: Conditions) -> Bool {
        guard !conditions.hasPendingLocalUploads, !conditions.hasUnmaterializedLocalEvidence,
            !conditions.hasPhotosAwaitingLibrary, !conditions.hasRestoredPhotos,
            !conditions.continuityRecoveryRequired,
            let basis = conditions.basis,
            basis.eventToken == conditions.currentEventToken,
            basis.revisions != conditions.currentRevisions
        else { return false }
        return true
    }

    /// Whether the stored inventory carries the validation token of this cursor, so it is the result of that load.
    static func storedInventoryIsOf(eventToken: String, storedValidationToken: String?) -> Bool {
        storedValidationToken == TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: eventToken)
    }

    /// Whether the stored inventory may be used, from the facts alone.
    static func isEligible(_ conditions: Conditions, storedValidationToken: String?) -> Bool {
        passesConditions(conditions)
            && storedInventoryIsOf(
                eventToken: conditions.currentEventToken, storedValidationToken: storedValidationToken)
    }

    /// A Live Photo whose motion is not read: it shows the Live control but names no video. A listing reads the
    /// related types again for it (`LivePhotoMotion.unknown`); a stored copy would keep it unread.
    static func hasUnreadLiveMotion(_ items: [PhotoItem]) -> Bool {
        items.contains { $0.isLivePhoto && $0.relatedVideoID == nil }
    }

    /// The sections to publish, or nil when the existing sources must run. The reads happen in order and only as far
    /// as needed: first the conditions, then the stored token, then the motion rule mark, then the stored items. A
    /// failed or empty read, a stored copy that the current motion rule did not choose and a Live Photo with an
    /// unread motion all give nil, so a damaged or incomplete store never replaces a listing.
    static func plan(
        _ conditions: Conditions,
        storedValidationToken: () -> String?,
        motionRuleIsCurrent: () -> Bool,
        storedItems: () throws -> [PhotoItem]?,
        mediaTypeEvidence: () -> [String: String]
    ) -> [TimelineSection]? {
        guard passesConditions(conditions),
            storedInventoryIsOf(
                eventToken: conditions.currentEventToken, storedValidationToken: storedValidationToken()),
            motionRuleIsCurrent()
        else { return nil }
        guard let stored = try? storedItems(), !stored.isEmpty, !hasUnreadLiveMotion(stored) else { return nil }
        return sections(from: stored, mediaTypeEvidence: mediaTypeEvidence())
    }

    /// The basis for the next load: the raw cursor and the revisions of a load whose inventory was saved. A load
    /// that was not saved (incomplete enrichment, failed save) leaves no basis, so the next load lists.
    static func basis(
        persistedValidationToken: String?, eventToken: String, revisions: TimelineLocalRevisions, saved: Bool
    ) -> TimelineLoadBasis? {
        guard saved, persistedValidationToken != nil else { return nil }
        return TimelineLoadBasis(eventToken: eventToken, revisions: revisions)
    }

    /// The stored items with the media-type evidence applied, grouped like a listing: one section, canonical order,
    /// no duration (a listing enumerates none, and a save keeps the durations learned later).
    static func sections(from stored: [PhotoItem], mediaTypeEvidence: [String: String]) -> [TimelineSection] {
        let items =
            stored
            .map { item -> PhotoItem in
                let mediaType = mediaTypeEvidence[item.uid.nodeID] ?? item.mediaType
                var tags = item.tags
                tags.remove(.videos)
                if mediaType.hasPrefix("video/") { tags.insert(.videos) }
                return PhotoItem(
                    uid: item.uid,
                    captureTime: item.captureTime,
                    mediaType: mediaType,
                    isLivePhoto: item.isLivePhoto,
                    relatedVideoID: item.relatedVideoID,
                    tags: tags,
                    burstMemberIDs: item.burstMemberIDs)
            }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
        return [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
    }
}
