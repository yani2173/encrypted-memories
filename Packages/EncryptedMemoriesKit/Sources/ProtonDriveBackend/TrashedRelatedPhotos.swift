import Foundation
import PhotosCore
import UploadCore

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
            guard let mainLink = links[main.nodeID], mainLink.hasExplicitPhotoState, !mainLink.isActive,
                let mainTrash = mainLink.trashTime
            else {
                continue
            }
            for frame in candidates[main] ?? [] where !restoring.contains(frame) {
                guard let link = links[frame.nodeID], link.hasExplicitPhotoState, !link.isActive,
                    frame.volumeID == main.volumeID, link.mainPhotoLinkID == main.nodeID,
                    let trash = link.trashTime, isWithinWindow(trash, of: mainTrash)
                else { continue }
                if seen.insert(frame).inserted { frames.append(frame) }
            }
        }
        return frames
    }

    /// A distance that does not fit into `Int64` lies outside the window: server values never trap.
    static func isWithinWindow(_ trash: Int64, of mainTrash: Int64) -> Bool {
        let (distance, overflow) = trash.subtractingReportingOverflow(mainTrash)
        return !overflow && distance.magnitude <= UInt64(trashedTogetherWindow)
    }

    /// Complete discovery certifies Restore candidates for this account session.
    /// The ordinary DriveSession listing tolerates omitted metadata; that cannot prove an empty frame set.
    static func checkedTrash(
        session: DriveSession, volumeID: String, retryOnRateLimit: Bool
    ) async throws -> [TrashLink] {
        var idsByShare: [String: [String]] = [:]
        var seenByShare: [String: Set<String>] = [:]
        var page = 0
        while true {
            try Task.checkCancellation()
            let response = try await session.getJSON(
                "/drive/volumes/\(volumeID)/trash?Page=\(page)&PageSize=150", as: CheckedTrashPage.self,
                retryOnRateLimit: retryOnRateLimit)
            guard response.code == 1000, response.complete else { throw incomplete }
            var count = 0
            var added = 0
            for group in response.trash {
                count += group.linkIDs.count
                for id in group.linkIDs where seenByShare[group.shareID, default: []].insert(id).inserted {
                    idsByShare[group.shareID, default: []].append(id)
                    added += 1
                }
            }
            if count < 150 { break }
            guard added > 0 else { throw DrivePaginationError.trashPageWithoutNewIDs(page) }
            page += 1
        }
        var result: [TrashLink] = []
        for share in idsByShare.keys.sorted() {
            let ids = idsByShare[share] ?? []
            let links = try await checkedMetadata(
                session: session, shareID: share, ids: ids, retryOnRateLimit: retryOnRateLimit)
            for entry in links {
                // Folders and albums grant no photo authority. Every other returned row needs explicit photo state.
                if entry.link.type == 1 || entry.link.type == 3 { continue }
                guard entry.visibility.hasExplicitPhotoState else { throw incomplete }
                result.append(entry.link)
            }
        }
        return result
    }

    static func checkedVisibility(
        session: DriveSession, shareID: String, ids: [String], retryOnRateLimit: Bool
    ) async throws -> [String: RemoteLinkVisibility] {
        var result: [String: RemoteLinkVisibility] = [:]
        for entry in try await checkedMetadata(
            session: session, shareID: shareID, ids: ids, retryOnRateLimit: retryOnRateLimit)
        {
            guard let id = entry.link.linkID else { throw incomplete }
            result[id] = entry.visibility
        }
        return result
    }

    private static var incomplete: UploadError { .backend("The link visibility response is incomplete") }

    private static func checkedMetadata(
        session: DriveSession, shareID: String, ids: [String], retryOnRateLimit: Bool
    ) async throws -> [CheckedLink] {
        let ids = Array(Set(ids)).sorted()
        var result: [CheckedLink] = []
        for chunk in ids.chunked(by: 150) {
            try Task.checkCancellation()
            let data = try await session.send(
                "/drive/shares/\(shareID)/links/fetch_metadata", method: "POST", body: ["LinkIDs": chunk],
                retryOnRateLimit: retryOnRateLimit)
            let response = try JSONDecoder().decode(CheckedMetadata.self, from: data)
            guard response.code == 1000, response.complete else { throw incomplete }
            var seen = Set<String>()
            for entry in response.links {
                guard let id = entry.link.linkID, chunk.contains(id), seen.insert(id).inserted else { throw incomplete }
                result.append(entry)
            }
        }
        return result
    }

    private struct CheckedTrashPage: Decodable {
        let code: Int
        let trash: [Group]
        let complete: Bool
        struct Group: Decodable {
            let shareID: String
            let linkIDs: [String]
            enum CodingKeys: String, CodingKey {
                case shareID = "ShareID"
                case linkIDs = "LinkIDs"
            }
        }
        enum CodingKeys: String, CodingKey {
            case code = "Code"
            case trash = "Trash"
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try values.decode(Int.self, forKey: .code)
            trash = try values.decode([Group].self, forKey: .trash)
            let fields = try decoder.container(keyedBy: Field.self)
            complete = fields.allKeys.allSatisfy { ["Code", "Trash"].contains($0.stringValue) }
        }
        private struct Field: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }

    private struct CheckedMetadata: Decodable {
        let code: Int
        let links: [CheckedLink]
        let complete: Bool
        enum CodingKeys: String, CodingKey {
            case code = "Code"
            case links = "Links"
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try values.decode(Int.self, forKey: .code)
            links = try values.decode([CheckedLink].self, forKey: .links)
            complete = try protonMetadataEnvelope(decoder: decoder).isComplete
        }
    }

    private struct CheckedLink: Decodable {
        let link: TrashLink
        let visibility: RemoteLinkVisibility
        enum CodingKeys: String, CodingKey {
            case state = "State"
            case trashTime = "Trashed"
        }
        init(from decoder: any Decoder) throws {
            link = try TrashLink(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let state = try values.decodeIfPresent(Int.self, forKey: .state)
            visibility = RemoteLinkVisibility(
                isActive: state == 1, mainPhotoLinkID: link.mainPhotoLinkID,
                trashTime: try values.decodeIfPresent(Int64.self, forKey: .trashTime),
                hasExplicitPhotoState: (state == 1 || state == 2) && link.fileProperties?.activeRevision?.photo != nil)
        }
    }

    /// Checks frame authority before any mutation. A failed preflight fails Restore with its original error.
    /// A failed main Restore retains its error after checking which mains explicitly came back.
    static func restore(
        _ mains: [PhotoUID],
        candidates: [PhotoUID: [PhotoUID]],
        readLinks: ([String]) async throws -> [String: RemoteLinkVisibility],
        rereadLinks: ([String]) async throws -> [String: RemoteLinkVisibility],
        restore: ([PhotoUID]) async throws -> Void,
        beforeMainRestore: ([String: RemoteLinkVisibility], [PhotoUID]) throws -> Void = { _, _ in },
        resumeFrames: (([PhotoUID]) async -> [PhotoUID])? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> [PhotoUID] {
        let related = mains.flatMap { candidates[$0] ?? [] }
        guard !related.isEmpty else {
            try await restore(mains)
            return []
        }
        let links = try await readLinks((mains + related).map(\.nodeID))
        guard (mains + related).allSatisfy({ links[$0.nodeID]?.hasExplicitPhotoState == true }) else {
            throw UploadError.backend("The link visibility response is incomplete")
        }
        let frames = restoredWith(mains, candidates: candidates, links: links)
        // A cancel during the read stops the restore before any photo changes.
        try Task.checkCancellation()
        try beforeMainRestore(links, frames)
        do {
            try await restore(mains)
        } catch let error as CancellationError {
            throw error
        } catch {
            // A batch error, or the error of a single request that Proton may have applied: some of the main photos may
            // be back. Their related photos follow; the error stays.
            guard !frames.isEmpty, !Task.isCancelled else { throw error }
            if let resumeFrames {
                _ = await resumeFrames(mains)
            } else if let now = try? await rereadLinks(mains.map(\.nodeID)) {
                let back = mains.filter {
                    now[$0.nodeID]?.isActive == true && now[$0.nodeID]?.hasExplicitPhotoState == true
                }
                _ = await restoreFrames(restoredWith(back, candidates: candidates, links: links), restore: restore)
            }
            throw error
        }
        if let resumeFrames { return await resumeFrames(mains) }
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
