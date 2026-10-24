import Foundation
import PhotosCore

/// Brings back the related photos that an earlier build moved to the trash together with their main photo.
///
/// Version 1.1.0 dissolved a series by moving every photo of it to the trash. Proton restores a related photo with its
/// main photo only when the related photo itself is not in the trash, so a restore of such a main photo brought it back
/// alone. The trash listing still returns those related photos with their main photo, and Recently Deleted hides them.
/// When the person restores the main photo, the related photos that moved to the trash within `trashedTogetherWindow` of it come back
/// too. A related photo that moved to the trash at another time, for example on purpose in another app, stays there.
enum TrashedRelatedPhotos {
    /// Five minutes: the largest distance between the server trash times of a main photo and of a related photo that
    /// left with it. 1.1.0 sent the photos of a series in one trash request, so their trash times lie seconds apart.
    static let trashedTogetherWindow: Int64 = 5 * 60

    /// Splits trash listing rows into the photos that Recently Deleted shows and the related photos of each main photo:
    /// Live Photo videos and frames that were trashed on their own. Both stay hidden, like in the timeline.
    static func split(_ links: [TrashLink], volumeID: String) -> (shown: [TrashLink], related: [PhotoUID: [PhotoUID]]) {
        var related: [PhotoUID: [PhotoUID]] = [:]
        for link in links {
            guard let id = link.linkID, let main = link.mainPhotoLinkID else { continue }
            related[PhotoUID(volumeID: volumeID, nodeID: main), default: []].append(
                PhotoUID(volumeID: volumeID, nodeID: id))
        }
        return (links.filter { $0.mainPhotoLinkID == nil }, related)
    }

    /// The related photos among `candidates` that come back with `mains`. Each one is in the trash, names its main photo
    /// as main photo, and moved to the trash within `trashedTogetherWindow` of that main photo, which is in the trash as well. Without
    /// both trash times nothing tells the photos apart, so the related photo stays in the trash.
    static func restoredWith(
        _ mains: [PhotoUID], candidates: [PhotoUID: [PhotoUID]], links: [String: RemoteLinkVisibility]
    ) -> [PhotoUID] {
        let restoring = Set(mains)
        var seen = Set<PhotoUID>()
        var frames: [PhotoUID] = []
        for main in mains {
            guard let mainLink = links[main.nodeID], !mainLink.isActive, let mainTrash = mainLink.trashTime else {
                continue
            }
            for frame in candidates[main] ?? [] where !restoring.contains(frame) {
                guard let link = links[frame.nodeID], !link.isActive, link.mainPhotoLinkID == main.nodeID,
                    let trash = link.trashTime, isWithinWindow(trash, of: mainTrash)
                else { continue }
                if seen.insert(frame).inserted { frames.append(frame) }
            }
        }
        return frames
    }

    /// A distance that does not fit into `Int64` lies outside the window: server values never trap.
    private static func isWithinWindow(_ trash: Int64, of mainTrash: Int64) -> Bool {
        let (distance, overflow) = trash.subtractingReportingOverflow(mainTrash)
        return !overflow && distance.magnitude <= UInt64(trashedTogetherWindow)
    }

    /// Restores `mains` and the related photos that left the library with them, and returns those related photos. The
    /// links are read before the restore, which ends the trash time of the main photo. A failed read, or a failed
    /// restore of the related photos, leaves them in the trash as before; only a failed restore of `mains` fails. When
    /// that restore fails after Proton restored some of `mains`, the related photos of those that came back follow
    /// before the error. `rereadLinks` reads their state then; unlike `readLinks` it may wait for a rate limit, because
    /// the main photos are back already. A cancel ends the restore without that step.
    static func restore(
        _ mains: [PhotoUID],
        candidates: [PhotoUID: [PhotoUID]],
        readLinks: ([String]) async throws -> [String: RemoteLinkVisibility],
        rereadLinks: ([String]) async throws -> [String: RemoteLinkVisibility],
        restore: ([PhotoUID]) async throws -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> [PhotoUID] {
        let related = mains.flatMap { candidates[$0] ?? [] }
        guard !related.isEmpty else {
            try await restore(mains)
            return []
        }
        var links: [String: RemoteLinkVisibility] = [:]
        do {
            links = try await readLinks((mains + related).map(\.nodeID))
        } catch {
            DebugLog.log("restore: related photo states unavailable - \(error)")
        }
        let frames = restoredWith(mains, candidates: candidates, links: links)
        // A cancel during the read stops the restore before any photo changes.
        try Task.checkCancellation()
        do {
            try await restore(mains)
        } catch let error as CancellationError {
            throw error
        } catch {
            // A batch error, or the error of a single request that Proton may have applied: some of the main photos may
            // be back. Their related photos follow; the error stays.
            guard !frames.isEmpty, !Task.isCancelled else { throw error }
            if let now = try? await rereadLinks(mains.map(\.nodeID)) {
                let back = mains.filter { now[$0.nodeID]?.isActive == true }
                _ = await restoreFrames(restoredWith(back, candidates: candidates, links: links), restore: restore)
            }
            throw error
        }
        return await restoreFrames(frames, restore: restore)
    }

    /// Restores the related photos and returns them. A failure leaves them in the trash and is no failure of the
    /// restore of their main photos.
    private static func restoreFrames(
        _ frames: [PhotoUID],
        restore: ([PhotoUID]) async throws -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async -> [PhotoUID] {
        guard !frames.isEmpty else { return [] }
        do {
            try await restore(frames)
        } catch {
            DebugLog.log("restore: related photos stay in the trash n=\(frames.count) - \(error)")
            return []
        }
        return frames
    }
}
