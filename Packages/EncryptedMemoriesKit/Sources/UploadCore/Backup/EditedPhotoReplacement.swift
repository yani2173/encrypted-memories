import Foundation
import PhotosCore

/// Remote reads and writes that replace an earlier upload with the edited photo. The backend implements it.
public protocol EditReplacementRemote: PhotoCarryOverRemote {
    /// Moves the photos that an edit replaced to the Proton trash, where the person can restore them. This is no
    /// deletion by the person.
    func trashReplaced(_ uids: [PhotoUID]) async throws
}

/// Replaces the earlier upload of an edited photo, so the library shows the photo once.
///
/// The backup calls it after the edited photo and all its secondaries are uploaded. The original is one of these
/// secondaries, so it stays in the backup as a related photo of the edited photo. The earlier photo passes its
/// favorite tag and its albums of the own library to the edited photo, then moves to the trash with its related
/// photos. Every step reads the server state again, so a retry after a failure repeats no write twice.
///
/// An earlier photo stays when the new compound does not hold the original, when an original resource of the photo
/// lives only under the earlier photo, when another local source still needs it or one of its related photos, or
/// when it carries the new photo. An adopted copy that nothing proves an upload of this photo also stays unless the
/// new photo holds a twin of each of its files. Other bytes replace the earlier photo only as an edit or as the undo
/// of an edit.
public struct EditedPhotoReplacement: Sendable {
    public enum Outcome: Sendable, Equatable {
        case replaced(retiredAny: Bool)
        /// At least one earlier main still protects an original resource that the new compound lacks.
        case waiting
        case kept
        /// Earlier mains would wait, but the photo that replaces them left the library, for example because the
        /// person trashed it. Nothing replaces them, and the photo is not backed up.
        case replacementGone
    }

    let remote: any EditReplacementRemote
    let albums: any SeriesAlbumCarryOver
    public let relations: any UploadDuplicateChecking
    public let identities: any UploadIdentityStore
    public let journal: any EditReplacementJournaling

    public init(
        remote: any EditReplacementRemote,
        albums: any SeriesAlbumCarryOver,
        relations: any UploadDuplicateChecking,
        identities: any UploadIdentityStore,
        journal: any EditReplacementJournaling
    ) {
        self.remote = remote
        self.albums = albums
        self.relations = relations
        self.identities = identities
        self.journal = journal
    }

    /// True when the new compound keeps the original in the backup: an unedited primary is the original itself,
    /// an edited one carries it as an original secondary. Only then may the earlier photo leave.
    public static func holdsOriginal(
        editRevision: UploadBackupEditRevision,
        secondaries: [UploadSourceIdentity.Resource]
    ) -> Bool {
        if case .revision = editRevision { return true }
        let originals = ["originalPhoto", "originalVideo"].map { "photoKit.\($0)." }
        return secondaries.contains { resource in originals.contains { resource.rawValue.hasPrefix($0) } }
    }

    /// True while an edit of `source` waits to replace its earlier upload, or while a gone earlier photo of it can be
    /// in the library. Its secondaries must then upload under the edited photo: their earlier copies move to the trash
    /// with the earlier photo, or belong to the person's photo that the backup never touches.
    public func isReplacing(_ source: UploadSourceIdentity) -> Bool {
        let entry = journal.entry(for: source)
        return !entry.allSuperseded.isEmpty || !(entry.gone ?? []).isEmpty
    }

    /// True when the next upload of `source` replaces its earlier uploads: an edit or the undo of an edit, also of a
    /// series. A false result keeps every earlier upload, so the upload must not name them as replaced. A compound
    /// without its original still names them: `replaceSuperseded` waits for the original before the trash write,
    /// and a reader counts a named link as replaced only after it left the library.
    public func replacesEarlierUploads(of source: UploadSourceIdentity, edited: Bool) -> Bool {
        journal.entry(for: source).replacesEarlierUploads(edited: edited)
    }

    /// Keeps the earlier uploads of `source`.
    private func keepSuperseded(of source: UploadSourceIdentity) throws {
        let superseded = journal.entry(for: source).allSuperseded
        guard !superseded.isEmpty else { return }
        try journal.settle(Set(superseded.map(\.nodeID)), related: [], trashed: false, for: source)
    }

    /// Reports whether earlier photos left, still wait for original resources, or stay for good. Cached duplicate
    /// rows are stale after retirement. The backup calls this after each upload of a photo.
    @discardableResult
    public func replaceSuperseded(
        of source: UploadSourceIdentity,
        with primary: PhotoUID,
        edited: Bool,
        holdsOriginal: Bool,
        externalIdentifier: String? = nil,
        localEditTime: Date? = nil,
        localCreationDate: Date? = nil,
        externalIdentifierIsUnique: Bool = false,
        originalSHA1Hex: Set<String> = []
    ) async throws -> Outcome {
        let entry = journal.entry(for: source)
        var superseded = entry.allSuperseded
        // A retry can use the manifest fast path, so recheck remote-only targets here as well as during discovery.
        // Unknown index state keeps these mains and leaves locally proven targets on their existing guarded path.
        let remoteTargets = Set(entry.remoteSuperseded ?? [])
        var provenCompounds: [String: UploadRemoteCompound] = [:]
        if !remoteTargets.isEmpty { await relations.invalidateCachedRemoteState() }
        for linkID in remoteTargets.sorted() {
            do {
                guard externalIdentifierIsUnique, let identifier = externalIdentifier,
                    let creationDate = localCreationDate,
                    let target = try await relations.compound(ofMainLink: linkID),
                    target.externalIdentifier == identifier,
                    UploadRemoteReplacementSafety.isSameCaptureSecond(remote: target.captureDate, local: creationDate)
                else { continue }
                let lineage = try await relations.replacedLinkIDs(ofReplacingMain: linkID)
                let heads = try await relations.activeMainLinkIDs(forExternalIdentifier: identifier)
                let successors = try await relations.replacingMainLinkIDs(ofReplacedLink: linkID)
                let otherHeads = heads.links.union(successors.links).subtracting([primary.nodeID])
                guard lineage.complete, heads.complete, successors.complete, otherHeads == [linkID],
                    UploadRemoteReplacementSafety.isNewerVersion(
                        localDate: localEditTime, remoteDate: target.modificationDate)
                else { continue }
                provenCompounds[linkID] = target
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if UploadError.isCancellation(error) { throw error }
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        let unknown = remoteTargets.subtracting(provenCompounds.keys)
        superseded.removeAll { unknown.contains($0.nodeID) }
        // Other bytes of a photo that is unedited now and was unedited before are no edit, so both photos stay.
        guard !superseded.isEmpty, entry.replacesEarlierUploads(edited: edited) else {
            try keepSuperseded(of: source)
            try recordUpload(of: source, edited: edited)
            return .kept
        }
        let volumeID = try await remote.ownPhotosVolumeID()
        func resolved(_ uid: PhotoUID) -> PhotoUID {
            uid.volumeID.isEmpty ? PhotoUID(volumeID: volumeID, nodeID: uid.nodeID) : uid
        }
        let replacement = resolved(primary)
        // The earlier photos may hold the only copy of the original. They wait for an upload that holds it.
        guard holdsOriginal else {
            return try await waitingOutcome(of: source, for: replacement, edited: edited)
        }
        // The edit was undone and the earlier photo is the current one again.
        var kept = Set(superseded.map(\.nodeID).filter { $0 == replacement.nodeID }).union(unknown)
        var waiting: Set<String> = []
        // A gone photo is the person's: the backup never trashes it, also after the person restored it.
        let protected = Set(entry.gone ?? [])
        kept.formUnion(superseded.map(\.nodeID).filter(protected.contains))
        let targets = superseded.map(resolved).filter {
            $0.nodeID != replacement.nodeID && !protected.contains($0.nodeID)
        }
        let active = try await remote.activeUIDs(among: targets)
        var trashable: [PhotoUID] = []
        var related = Set(
            targets.filter { !active.contains($0) }.flatMap { entry.retireIntent?[$0.nodeID] ?? [] })
        var intent: [String: [String]] = [:]
        // Read at most once, and only for a target without proof.
        var replacementCompound: UploadRemoteCompound?
        var replacementRead = false
        for target in targets where active.contains(target) {
            try Task.checkCancellation()
            let linked: Set<String>
            var unproven: UploadRemoteCompound?
            if remoteTargets.contains(target.nodeID) {
                do {
                    guard let earlier = provenCompounds[target.nodeID],
                        let newer = try await relations.compound(ofMainLink: replacement.nodeID)
                    else {
                        kept.insert(target.nodeID)
                        continue
                    }
                    var originals: Set<String> = []
                    for sha1 in originalSHA1Hex {
                        originals.insert(try await relations.contentHash(forSHA1Hex: sha1))
                    }
                    guard
                        UploadRemoteReplacementSafety.preserves(
                            earlier, with: newer, originalHashes: originals, source: source, identities: identities)
                    else {
                        kept.insert(target.nodeID)
                        continue
                    }
                    linked = Set(earlier.related.map(\.linkID))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if UploadError.isCancellation(error) { throw error }
                    try Task.checkCancellation()
                    kept.insert(target.nodeID)
                    continue
                }
            } else if (entry.proven ?? []).contains(target.nodeID) {
                linked = try await relations.relatedPhotoLinkIDs(ofMainLinkID: target.nodeID)
            } else {
                // Nothing proves an upload of this photo: a reset manifest adopts an own upload again, but an adopted
                // copy can also be another device's upload whose related files exist only there.
                guard let earlier = try await readCompound(ofMainLink: target.nodeID) else {
                    kept.insert(target.nodeID)
                    continue
                }
                unproven = earlier
                linked = Set(earlier.related.map(\.linkID))
            }
            let links = linked.union([target.nodeID])
            // The trash takes related photos along: the server hides them with their main photo, a restore brings
            // them back, and a final deletion removes them. They stay active links, so only the main photo moves.
            // A photo that carries the edited photo stays, and so does a photo that another local source, such as a
            // duplicate in Photos, still counts as its backup.
            guard !linked.contains(replacement.nodeID), !identities.isNeededElsewhere(links, by: source) else {
                kept.insert(target.nodeID)
                continue
            }
            // An original resource of this photo lives only there. The photo waits for an upload that carries it.
            guard !leavesOriginalBehind(links, of: source, primaryIsOriginal: !edited) else {
                waiting.insert(target.nodeID)
                continue
            }
            // An unproven photo leaves only when the trash loses no file: the new photo holds a twin of each.
            if let earlier = unproven {
                if !replacementRead {
                    replacementCompound = try await readCompound(ofMainLink: replacement.nodeID)
                    replacementRead = true
                }
                guard let newer = replacementCompound,
                    UploadRemoteReplacementSafety.keepsEveryFile(of: earlier, under: newer)
                else {
                    kept.insert(target.nodeID)
                    continue
                }
            }
            trashable.append(target)
            related.formUnion(linked)
            intent[target.nodeID] = linked.sorted()
        }
        try Task.checkCancellation()
        try journal.clearRetireIntent(Set(active.map(\.nodeID)), for: source)
        // A cached membership can miss an album that another device added; the trash would lose it.
        try await remote.carryOver(
            from: trashable, to: replacement, ownVolumeID: volumeID, albums: CurrentAlbumCarryOver(base: albums))
        if !trashable.isEmpty {
            // A crash after the trash loses the server's related listing. The intent keeps those links without
            // retiring them until the main's trash is confirmed.
            try journal.prepareToRetire(intent, for: source)
            try await remote.trashReplaced(trashable)
        }
        // An earlier photo that left the library counts as retired only with proof that this backup trashed it: the
        // intent this device wrote before its trash. A marker of another upload names what it replaces, not who
        // trashed it. Without proof the person may have trashed it, so it is gone: the backup never trashes it
        // again, and its trash is no deletion proof.
        var retired = Set(trashable.map(\.nodeID))
        var gone: Set<String> = []
        for target in targets where !active.contains(target) {
            if entry.retireIntent?[target.nodeID] != nil {
                retired.insert(target.nodeID)
            } else {
                gone.insert(target.nodeID)
            }
        }
        // A row that names a trashed photo no longer proves a backup. Related links from an earlier intent join
        // confirmed retired links, so a retry after a failed manifest write forgets them too.
        let trashedLinks = retired.union(gone).union(related).union(journal.entry(for: source).retired)
        guard identities.forgetRemoteLinks(trashedLinks, of: source) else {
            throw UploadError.backend("Upload identity manifest could not be updated")
        }
        try journal.settle(retired, related: related, trashed: true, for: source)
        try journal.settleGone(gone, for: source)
        try journal.settle(kept, related: [], trashed: false, for: source)
        if !waiting.isEmpty { return try await waitingOutcome(of: source, for: replacement, edited: edited) }
        try recordUpload(of: source, edited: edited)
        return retired.isEmpty && gone.isEmpty ? .kept : .replaced(retiredAny: true)
    }

    /// Earlier photos wait only for a photo that is in the library. When the photo that would replace them left it,
    /// for example because the person trashed it, nothing can replace them, and they stay.
    ///
    /// A waiting replacement is unsettled: the journal notes an uploaded edit, so a later undo still replaces it,
    /// but an undo that waits does not clear the note, or its own retry would keep the edit for good.
    private func waitingOutcome(
        of source: UploadSourceIdentity, for replacement: PhotoUID, edited: Bool
    ) async throws -> Outcome {
        if edited { try recordUpload(of: source, edited: true) }
        return try await remote.activeUIDs(among: [replacement]).contains(replacement) ? .waiting : .replacementGone
    }

    /// The compound of a main photo, or nil when the server state is incomplete or the read fails for good. The photo
    /// then stays, so such a read never blocks the upload. A network or temporary service failure throws, so the
    /// backup retries the whole replacement later, like a failed read of a proven photo.
    private func readCompound(ofMainLink linkID: String) async throws -> UploadRemoteCompound? {
        do {
            return try await relations.compound(ofMainLink: linkID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if UploadError.isCancellation(error) { throw error }
            try Task.checkCancellation()
            if case UploadError.retryableBackend = error { throw error }
            if BackupSyncRunner.isTransientNetwork(error) { throw error }
            return nil
        }
    }

    private func recordUpload(of source: UploadSourceIdentity, edited: Bool) throws {
        guard source.kind == .photoLibraryAsset else { return }
        try journal.recordUpload(edited: edited, for: source)
    }

    /// True when a row of `source` with an original resource still names one of `linkIDs`: the new compound did not
    /// upload that resource again, because its rows moved to the new photos. An unedited primary is the original
    /// photo or video itself.
    private func leavesOriginalBehind(
        _ linkIDs: Set<String>, of source: UploadSourceIdentity, primaryIsOriginal: Bool
    ) -> Bool {
        linkIDs.contains { linkID in
            (identities.sources(withRemoteLinkID: linkID) ?? []).contains { row in
                row.kind == source.kind && row.identifier == source.identifier
                    && Self.isOriginal(row.resource, carriedByPrimary: primaryIsOriginal)
                    && !holdsTwin(of: row, outside: linkIDs)
            }
        }
    }

    /// True when the other identity of the same paired video names a photo outside `linkIDs`. The Live effect picks
    /// the identity: with the effect on the video is the Live Photo video, with the effect off a plain related file.
    /// A toggle uploads the video again under its other identity, so the row of the earlier identity stays behind.
    private func holdsTwin(of row: UploadSourceIdentity, outside linkIDs: Set<String>) -> Bool {
        let plain = UploadSourceIdentity.Resource.photoKit(role: "pairedVideo", ordinal: 0)
        let twinResource: UploadSourceIdentity.Resource
        switch row.resource {
        case .livePairedVideo: twinResource = plain
        case plain: twinResource = .livePairedVideo
        default: return false
        }
        let twin = UploadSourceIdentity(kind: row.kind, identifier: row.identifier, resource: twinResource)
        guard let linkID = identities.record(for: twin)?.remoteLinkID, !linkIDs.contains(linkID) else { return false }
        return identities.sources(withRemoteLinkID: linkID)?.contains(twin) == true
    }

    /// The resources that Photos keeps unchanged through an edit: the original photo or video, a RAW alternate,
    /// and the paired video of a Live Photo.
    static func isOriginal(_ resource: UploadSourceIdentity.Resource, carriedByPrimary: Bool) -> Bool {
        if resource == .livePairedVideo { return true }
        let roles = ["alternatePhoto", "pairedVideo"] + (carriedByPrimary ? [] : ["originalPhoto", "originalVideo"])
        return roles.contains { resource.rawValue.hasPrefix("photoKit.\($0).") }
    }
}

/// Conservative ordering for remote heads. Multiple heads need a later resolution flow.
enum UploadRemoteReplacementSafety {
    static func isNewerVersion(localDate: Date?, remoteDate: Date?) -> Bool {
        guard let localDate, let remoteDate else { return false }
        return localDate > remoteDate
    }

    /// The server stores the capture time in whole seconds, so a PhotoKit date matches by its second.
    static func isSameCaptureSecond(remote: Date?, local: Date) -> Bool {
        guard let remote else { return false }
        return remote.timeIntervalSince1970.rounded(.down) == local.timeIntervalSince1970.rounded(.down)
    }

    static func hasAnchor(_ compound: UploadRemoteCompound, originalHashes: Set<String>) -> Bool {
        ([compound.main] + compound.related).contains { originalHashes.contains($0.contentHash) }
    }

    static func preserves(
        _ target: UploadRemoteCompound, with replacement: UploadRemoteCompound, originalHashes: Set<String>,
        source: UploadSourceIdentity, identities: any UploadIdentityStore
    ) -> Bool {
        guard hasAnchor(target, originalHashes: originalHashes) else { return false }
        let files = [replacement.main] + replacement.related
        let retainedOriginals = Set(files.map(\.contentHash)).intersection(originalHashes)
        let anchors = ([target.main] + target.related).filter { retainedOriginals.contains($0.contentHash) }
        guard !anchors.isEmpty else { return false }
        var used: Set<String> = []
        for file in target.related {
            if contentTwin(of: file, among: files, used: &used) != nil { continue }
            guard !files.contains(where: { $0.contentHash == file.contentHash }) else { return false }
            let derived = replacement.related.filter { candidate in
                guard candidate.nameHash == file.nameHash, candidate.mimeType == file.mimeType,
                    let rows = identities.sources(withRemoteLinkID: candidate.linkID)
                else { return false }
                return rows.contains { row in
                    row.kind == source.kind && row.identifier == source.identifier && isEditRole(row.resource)
                }
            }
            guard derived.count == 1, let match = derived.first, !used.contains(match.linkID) else { return false }
            used.insert(match.linkID)
        }
        if files.contains(where: { $0.contentHash == target.main.contentHash && !used.contains($0.linkID) }) {
            return true
        }
        return target.related.contains { retainedOriginals.contains($0.contentHash) }
    }

    /// The first file of `files` with the content of `file` that no earlier file took. It counts as taken afterwards,
    /// so two related files never share one twin.
    static func contentTwin(
        of file: UploadRemoteCompound.File, among files: [UploadRemoteCompound.File], used: inout Set<String>
    ) -> UploadRemoteCompound.File? {
        guard let twin = files.first(where: { $0.contentHash == file.contentHash && !used.contains($0.linkID) })
        else { return nil }
        used.insert(twin.linkID)
        return twin
    }

    /// The twin under `kept` of every related file of `duplicate`, by link. Nil when a related file has no twin:
    /// the trash of `duplicate` would take its only copy along.
    static func relatedTwins(
        of duplicate: UploadRemoteCompound, under kept: UploadRemoteCompound
    ) -> [String: UploadRemoteCompound.File]? {
        var used: Set<String> = []
        var twins: [String: UploadRemoteCompound.File] = [:]
        for file in duplicate.related {
            guard let twin = contentTwin(of: file, among: kept.related, used: &used) else { return nil }
            twins[file.linkID] = twin
        }
        return twins
    }

    /// True when the trash of `target` loses no file: each related file and the main file of `target` has its own
    /// twin under `replacement`.
    static func keepsEveryFile(of target: UploadRemoteCompound, under replacement: UploadRemoteCompound) -> Bool {
        guard let twins = relatedTwins(of: target, under: replacement) else { return false }
        var used = Set(twins.values.map(\.linkID))
        return contentTwin(of: target.main, among: [replacement.main] + replacement.related, used: &used) != nil
    }

    static func isEditRole(_ resource: UploadSourceIdentity.Resource) -> Bool {
        let roles = [
            "adjustmentData", "adjustmentBasePhoto", "adjustmentBaseVideo", "adjustmentBasePairedVideo",
            "fullSizePhoto", "fullSizeVideo", "fullSizePairedVideo",
        ]
        return roles.contains { resource.rawValue.hasPrefix("photoKit.\($0).") }
    }
}
