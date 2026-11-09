import Foundation
import PhotosCore

/// Remote reads and writes of the revert to original. The backend implements it; tests use a fake.
public protocol EditedOriginalRevertRemote: EditReplacementRemote, OriginalFileProvider {
    /// Metadata of the hidden original: filename, type, capture time and encrypted sections.
    func originalSource(for uid: PhotoUID) async throws -> EditedOriginalSource
}

/// Metadata of the hidden original that the restored copy keeps. The revert to original uses this source
/// alongside the shared copy helper, mirroring the series dissolution without duplication.
public struct EditedOriginalSource: Sendable, Equatable {
    public let filename: String
    public let mediaType: String
    public let captureTime: Date
    public let modificationDate: Date
    public let additionalMetadata: [PhotoUploadAdditionalMetadata]

    public init(
        filename: String,
        mediaType: String,
        captureTime: Date,
        modificationDate: Date,
        additionalMetadata: [PhotoUploadAdditionalMetadata]
    ) {
        self.filename = filename
        self.mediaType = mediaType
        self.captureTime = captureTime
        self.modificationDate = modificationDate
        self.additionalMetadata = additionalMetadata
    }
}

extension EditedOriginalSource {
    /// The hidden original is read like a series member: both reads keep the metadata that the copy carries.
    public init(_ member: SeriesMemberSource) {
        self.init(
            filename: member.filename, mediaType: member.mediaType, captureTime: member.captureTime,
            modificationDate: member.modificationDate, additionalMetadata: member.additionalMetadata)
    }
}

/// The outcome of a resume attempt that finished in the trash step. The host reports the restored copy or the
/// error that kept the operation pending.
public struct EditedOriginalRevertResumeOutcome: Sendable {
    public let editedMainUID: PhotoUID
    public let result: Result<PhotoUID, any Error>
}

// MARK: - Orchestrator

/// Restores the hidden original of an edited photo as a standalone photo, carries the edited photo's favorite
/// tag and own albums over, and moves only the edited photo to the trash. Every step reads the server state
/// again, so a retry after a failure repeats no write twice.
///
/// The host keeps one instance of this actor per account: the `running` guard below works per instance, and
/// two instances could write the same journal concurrently.
///
/// The restored photo's name, "`<base> (original).<ext>`" with the original's extension, is decided by the
/// caller. Checks on whether a revert is allowed at all, such as the original being reachable, are not part
/// of this type.
public actor EditedOriginalRevert {
    public enum RevertError: Error, Equatable {
        /// A revert for this edited main is already running.
        case editAlreadyRunning
        /// The edited photo was already moved to the trash by an earlier attempt or another device.
        case editAlreadyTrashed
        /// The restored copy did not confirm as an active photo on the server.
        case copyNotConfirmed
        /// The edited photo did not leave the library after the trash request.
        case editNotTrashed
        /// Another client's draft blocks the restore; the payload is the person's source filename. The
        /// revert stays resumable.
        case blockedByForeignDraft(String)
        /// The restored name is missing or empty. The caller decides the name, so no copy was attempted.
        case invalidRestoredName
        /// The given original does not match the journal of the interrupted revert.
        case originalMismatch
    }

    private let remote: any EditedOriginalRevertRemote
    private let albums: any SeriesAlbumCarryOver
    private let copier: RelatedPhotoCopier
    private let relations: any UploadDuplicateChecking
    private let journalStore: any EditedOriginalRevertJournalStore
    private let admission: JoinedShutdownGate
    private var running: Set<PhotoUID> = []

    public init(
        remote: any EditedOriginalRevertRemote,
        albums: any SeriesAlbumCarryOver,
        copier: RelatedPhotoCopier,
        relations: any UploadDuplicateChecking,
        journalStore: any EditedOriginalRevertJournalStore,
        admission: JoinedShutdownGate
    ) {
        self.remote = remote
        self.albums = albums
        self.copier = copier
        self.relations = relations
        self.journalStore = journalStore
        self.admission = admission
    }

    /// Restores the hidden original of `editedMain` as a standalone photo named by `restoredName`, carries the
    /// edited photo's favorite tag and own albums over, then moves only the edited photo to the trash. Returns
    /// the restored photo's UID. Safe to call again after any failure or crash.
    @discardableResult
    public func revert(
        editedMain: PhotoUID,
        original: PhotoUID,
        restoredName: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PhotoUID {
        try await admission.withAdmission { [self] in
            guard !restoredName.isEmpty else { throw RevertError.invalidRestoredName }
            var journal: EditedOriginalRevertJournal
            if var existing = try journalStore.decodableJournal(forEditedMain: editedMain) {
                // An interrupted operation keeps its journal: a trash step continues, and a copy step reuses the
                // confirmed copy instead of downloading and uploading the original again. The name is decided
                // deterministically by the caller, so it refreshes a journal that an older build wrote. The
                // original must be the one that the interrupted revert started from: another related file
                // would restore the wrong bytes.
                guard original.nodeID == existing.originalLinkID else { throw RevertError.originalMismatch }
                existing.restoredName = restoredName
                journal = existing
            } else {
                // The original UID node ID is the link ID of the related file that holds the original bytes.
                journal = EditedOriginalRevertJournal(
                    editedMainUID: editedMain, originalLinkID: original.nodeID, restoredName: restoredName)
            }
            // The person asked for this revert, so it may make the copy.
            return try await self.run(&journal, allowsNewCopy: true, onProgress: onProgress)
        }
    }

    /// Drops the journal of a revert that the user left after a failure: Cancel or closing the photo. Only a
    /// journal that still copies is removed; the edited photo is untouched in that phase, and a copy that is
    /// already confirmed stays as a standalone photo. A journal in the trash step is final, because the
    /// user's consent and the copy are fixed there; it finishes over `resumePending`. A journal whose content
    /// cannot be decoded is removed whatever its phase is: its phase is unknown, the person asked to cancel,
    /// and no photo goes to the trash without a confirmed copy, so the edited photo stays active unless the
    /// trash step already moved it.
    public func abandon(editedMain: PhotoUID) async throws {
        try await admission.withAdmission { [self] in
            try await self.admittedAbandon(editedMain: editedMain)
        }
    }

    private func admittedAbandon(editedMain: PhotoUID) throws {
        guard !running.contains(editedMain) else { throw RevertError.editAlreadyRunning }
        // An undecodable journal is removed like a copying one: it cannot be resumed, and the person asked
        // to cancel, so the file must not outlive the request as a dead end. A file that cannot be read
        // still throws below, so it is never removed unheard.
        guard let journal = try journalStore.decodableJournal(forEditedMain: editedMain) else {
            try journalStore.remove(forEditedMain: editedMain)
            return
        }
        guard journal.phase == .copying else { return }
        try journalStore.remove(forEditedMain: editedMain)
    }

    /// Finishes every interrupted operation that reached the trash step, and reports each result to the host.
    /// The host calls this without a tap of the person, so it never makes a copy: it does not download, upload or
    /// carry over anything. A journal that still copies, and a journal whose confirmed copy is gone, wait for the
    /// person to re-trigger the revert. Such a journal stays unchanged and produces no outcome.
    public func resumePending(
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [EditedOriginalRevertResumeOutcome] {
        return try await admission.withAdmission { [self] in
            var outcomes: [EditedOriginalRevertResumeOutcome] = []
            for var journal in try journalStore.pendingJournals() {
                try Task.checkCancellation()
                let result: Result<PhotoUID, any Error>
                do {
                    let copyUID = try await run(&journal, allowsNewCopy: false, onProgress: onProgress)
                    result = .success(copyUID)
                } catch is ResumeNeedsPerson {
                    // No step of this journal wrote to the server, and the journal is unchanged: the person's next
                    // Revert tap continues it.
                    continue
                } catch RevertError.editAlreadyRunning {
                    // The person's tap runs this journal right now and finishes it itself. This is no failed step,
                    // and the check sits at the insertion into `running`, so no earlier snapshot of the running
                    // edits can go stale.
                    continue
                } catch {
                    result = .failure(error)
                }
                outcomes.append(.init(editedMainUID: journal.editedMainUID, result: result))
            }
            return outcomes
        }
    }

    /// A resume without the person's tap found that the journal needs a new copy. Internal signal of `run`.
    private struct ResumeNeedsPerson: Error {}

    /// `allowsNewCopy` is true only for a revert that the person started. A resume passes false, so it can finish
    /// the trash and device steps of a confirmed copy but never makes a copy.
    private func run(
        _ journal: inout EditedOriginalRevertJournal,
        allowsNewCopy: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoUID {
        let mainUID = journal.editedMainUID
        guard running.insert(mainUID).inserted else { throw RevertError.editAlreadyRunning }
        defer { running.remove(mainUID) }

        if !allowsNewCopy {
            // A resume has no tap behind it. It never continues a journal that still copies: that would write the
            // favorite tag and the albums of a copy that the person has not confirmed again.
            guard journal.phase != .copying else { throw ResumeNeedsPerson() }
            // The resume works from a list that it read earlier. A tap can finish, fail or move on while the resume
            // waits on another journal. The resume acts only on the journal that is on disk right now, so it never
            // brings back a removed journal and never writes an older state over a newer one.
            guard try journalStore.decodableJournal(forEditedMain: mainUID) == journal else {
                throw ResumeNeedsPerson()
            }
        }

        // The journal exists before the first remote write, so every later state is recoverable.
        try journalStore.save(journal)

        // A copy can vanish between its confirmation and now (a crash, then a manual delete), and a journal can
        // reach this point without a copy. Re-check the server in every phase, and make the copy again when it is
        // missing or no longer active. Only a confirmed active copy allows the trash step. The device-side phase
        // is exempt: its server writes are done and the edited main is already in the trash, so the copy cannot be
        // made again. Lowering that phase would drop the device-side step and make the journal invisible to a
        // later resume, because the resume filter skips a journal that is still copying.
        if journal.phase != .repointingDevice, try await copyMustBeMadeAgain(journal) {
            // The resume at app start has no tap behind it. The journal stays as it is.
            guard allowsNewCopy else { throw ResumeNeedsPerson() }
            journal.phase = .copying
            journal.copyUID = nil
            // The carry-over of the old copy is void with it: the new copy needs the favorite tag and the albums
            // again, or it would silently miss both.
            journal.favoriteDone = false
            journal.addedAlbumIDs = []
            try journalStore.save(journal)
        }

        if journal.phase == .copying {
            try await ensureCopy(&journal, onProgress: onProgress)
            guard try await !copyIsInactive(journal) else { throw RevertError.copyNotConfirmed }
            try await carryOverFavoriteAndAlbums(&journal)
            try Task.checkCancellation()
            journal.phase = .trashingEdit
            try journalStore.save(journal)
        }

        if journal.phase == .trashingEdit {
            try await trashEditedMain(journal)
            // The device-side step gets its own saved phase before it runs, so a crash during it keeps the
            // journal and the resume finishes that step instead of losing it.
            journal.phase = .repointingDevice
            try journalStore.save(journal)
        }

        // Device side: forget earlier backup states of the edited source and re-point the manifest at the copy.
        // TODO (step 6): integration with UploadBackupState.forgetEarlierStates and UploadIdentityManifestStore.sources
        // Reserved for commit 3; the saved `.repointingDevice` phase above is the crash-recovery contract for it.
        try journalStore.remove(forEditedMain: mainUID)
        await relations.invalidateCachedRemoteState()
        return try copyUID(of: journal)
    }

    private func ensureCopy(
        _ journal: inout EditedOriginalRevertJournal,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard journal.copyUID == nil else { return }
        // Only a tap reaches this step, and `revert` sets the name first, so this guard has no direct test: no
        // public call reaches it. It stays as a defense against a journal that an older build wrote without a name.
        guard let uploadName = journal.restoredName, !uploadName.isEmpty else { throw RevertError.invalidRestoredName }
        // The server refuses the related list of a main in the trash, on every attempt. Fail with the precise
        // cause instead, so the host can offer `abandon` instead of a dead end.
        guard try await remote.activeUIDs(among: [journal.editedMainUID]).contains(journal.editedMainUID) else {
            throw RevertError.editAlreadyTrashed
        }
        let originalUID = PhotoUID(volumeID: journal.editedMainUID.volumeID, nodeID: journal.originalLinkID)
        let originalSource = try await remote.originalSource(for: originalUID)
        do {
            let relatedIDs = try await relations.relatedPhotoLinkIDs(ofMainLinkID: journal.editedMainUID.nodeID)
            let compoundLinkIDs = Set([journal.editedMainUID.nodeID] + relatedIDs)
            let lineageMetadata = UploadLineageMarker(reason: .undo, replaces: [journal.editedMainUID.nodeID])?
                .additionalMetadata
            let copyUID = try await copier.makeStandaloneCopy(
                sourceUID: originalUID,
                source: originalSource,
                uploadName: uploadName,
                extraMetadata: lineageMetadata.map { [$0] } ?? [],
                sourceLinkID: journal.originalLinkID,
                compoundLinkIDs: compoundLinkIDs,
                onProgress: onProgress
            )
            journal.copyUID = copyUID
            try journalStore.save(journal)
        } catch RelatedPhotoCopyError.blockedByForeignDraft(occupiedName: _, sourceFilename: let filename) {
            // The revert reports the person's source filename, not the corrected upload name.
            throw RevertError.blockedByForeignDraft(filename)
        }
    }

    private func carryOverFavoriteAndAlbums(_ journal: inout EditedOriginalRevertJournal) async throws {
        try Task.checkCancellation()
        let copy = try copyUID(of: journal)
        let ownVolumeID = try await remote.ownPhotosVolumeID()
        if !journal.favoriteDone {
            // The favorite tag moves only when the edited photo carries it. A re-read after a crash cannot tag
            // the copy twice, because the write is the same tag on the same photo.
            let favorites = try await remote.favoriteUIDs(among: [journal.editedMainUID, copy])
            if !favorites.contains(copy), favorites.contains(journal.editedMainUID) {
                try await remote.markFavorite([copy])
            }
            journal.favoriteDone = true
            try journalStore.save(journal)
        }
        // Own albums only: a shared album cannot be addressed by this client. Each confirmed write is journaled,
        // so a retry never adds the copy to the same album twice.
        let all = try await albums.currentAlbums(containing: [journal.editedMainUID])
        let ownAlbums = (all[journal.editedMainUID] ?? [])
            .filter { $0.volumeID == ownVolumeID && !journal.addedAlbumIDs.contains($0.albumID) }
        for album in ownAlbums {
            try Task.checkCancellation()
            try await albums.addPhotos([copy], toOwnAlbum: album.albumID)
            journal.addedAlbumIDs.append(album.albumID)
            try journalStore.save(journal)
        }
    }

    private func trashEditedMain(_ journal: EditedOriginalRevertJournal) async throws {
        let editedMain = journal.editedMainUID
        // Never trash the edited main without a copy that is an active standalone photo right now. Without this
        // check, a journal whose copy is gone, or whose "copy" is a related file of the edited photo, would put
        // both photos in the trash and leave the library empty.
        let copy = try copyUID(of: journal)
        // One batched read answers both questions: is the copy an active photo, and is the edited main still in
        // the library?
        let active = try await remote.activeUIDs(among: [copy, editedMain])
        guard active.contains(copy), try await isStandaloneMain(copy) else { throw RevertError.copyNotConfirmed }
        // A resumed trash step skips a main that an earlier attempt already moved.
        guard active.contains(editedMain) else { return }
        // Trash only the edited main (trashReplaced); related files follow with their main.
        try await remote.trashReplaced([editedMain])
        // Confirm by the main's state alone: the main must no longer be active. Otherwise the journal stays for
        // the next attempt.
        guard try await remote.activeUIDs(among: [editedMain]).isEmpty else {
            throw RevertError.editNotTrashed
        }
    }

    /// True when the journal's copy must be made again: the journal reached the trash step without a copy, or
    /// its confirmed copy is no longer an active photo on the server.
    private func copyMustBeMadeAgain(_ journal: EditedOriginalRevertJournal) async throws -> Bool {
        guard journal.copyUID != nil else { return journal.phase == .trashingEdit }
        return try await copyIsInactive(journal)
    }

    /// True when the journal's confirmed copy is not an active standalone photo on the server. A related file
    /// also counts as active in `activeUIDs`, so a hidden related file must not pass as a confirmed copy.
    private func copyIsInactive(_ journal: EditedOriginalRevertJournal) async throws -> Bool {
        guard let copyUID = journal.copyUID else { return false }
        guard try await remote.activeUIDs(among: [copyUID]).contains(copyUID) else { return true }
        return try await !isStandaloneMain(copyUID)
    }

    /// True when `photo` is an active photo with no main photo of its own, read freshly from the server. An
    /// absent link in the answer counts as not standalone, so the check fails closed. Role data can be missing
    /// from the answer; without it `mainPhotoLinkID` is nil even for a related file, so a link without explicit
    /// Photo state also counts as not standalone.
    private func isStandaloneMain(_ photo: PhotoUID) async throws -> Bool {
        let visibility = try await relations.linkVisibility(of: [photo.nodeID])
        guard let state = visibility[photo.nodeID], state.hasExplicitPhotoState else { return false }
        return state.isActiveMain
    }

    private func copyUID(of journal: EditedOriginalRevertJournal) throws -> PhotoUID {
        guard let copyUID = journal.copyUID else { throw RevertError.copyNotConfirmed }
        return copyUID
    }
}

extension EditedOriginalRevert.RevertError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .editAlreadyRunning: return "A revert for this edited photo is already running."
        case .editAlreadyTrashed: return "The edited photo was already in the trash."
        case .copyNotConfirmed: return "The restored copy is not an active photo on the server."
        case .editNotTrashed: return "The edited photo did not leave the library."
        case .blockedByForeignDraft: return "Another client's draft blocks the name."
        case .invalidRestoredName: return "The restored photo has no name."
        case .originalMismatch: return "The original does not match the interrupted revert."
        }
    }
}
