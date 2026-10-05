import Foundation
import PhotosCore

// MARK: - Seams

/// What the standalone copy of one series member keeps from its source: the original filename, type and
/// capture time, plus Proton's encrypted metadata sections that do not identify the source asset.
public struct SeriesMemberSource: Sendable, Equatable {
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

/// One album that contains a photo. `volumeID` tells an album of the own library from a shared album.
public struct SeriesAlbumReference: Sendable, Hashable {
    public let volumeID: String
    public let albumID: String

    public init(volumeID: String, albumID: String) {
        self.volumeID = volumeID
        self.albumID = albumID
    }
}

/// Remote reads and writes that give a new photo the place of photos that leave the library: the series
/// dissolution and the replacement of an edited photo share them. The backend implements it; tests use a fake.
public protocol PhotoCarryOverRemote: Sendable {
    /// The account's own photos volume. A photo in any other volume belongs to a shared album.
    func ownPhotosVolumeID() async throws -> String
    /// The subset of `uids` that are active photos now: not trashed, not deleted, not drafts.
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID>
    /// The subset of `uids` that carry Proton's favorite tag now.
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID>
    /// Adds Proton's favorite tag to the photos. Fails when any photo does not confirm the tag.
    func markFavorite(_ uids: [PhotoUID]) async throws
}

extension PhotoCarryOverRemote {
    /// Gives `replacement` the favorite tag and the own albums of the photos in `earlier`, before they leave the
    /// library. The edit replacement and the duplicate merge share it.
    public func carryOver(
        from earlier: [PhotoUID], to replacement: PhotoUID, ownVolumeID: String, albums: any SeriesAlbumCarryOver
    ) async throws {
        guard !earlier.isEmpty else { return }
        try await carryOver(
            from: earlier, to: replacement, ownVolumeID: ownVolumeID, albums: albums,
            favorites: favoriteUIDs(among: earlier + [replacement]))
    }

    /// `carryOver(from:to:ownVolumeID:albums:)` with the favorites among `earlier` and `replacement` that the caller
    /// read before, so one listing serves many carry-overs.
    public func carryOver(
        from earlier: [PhotoUID], to replacement: PhotoUID, ownVolumeID: String, albums: any SeriesAlbumCarryOver,
        favorites: Set<PhotoUID>
    ) async throws {
        guard !earlier.isEmpty else { return }
        if !favorites.contains(replacement), earlier.contains(where: favorites.contains) {
            try await markFavorite([replacement])
        }
        // Every album gets the add: a cached membership of `replacement` can be stale, and an existing membership
        // counts as success, so a retry adds nothing twice.
        for albumID in try await albums.ownAlbumIDs(containing: earlier, ownVolumeID: ownVolumeID) {
            try Task.checkCancellation()
            try await albums.addPhotos([replacement], toOwnAlbum: albumID)
        }
    }
}

/// Remote reads and the trash write of a series dissolution.
public protocol SeriesDissolutionRemote: OriginalFileProvider, PhotoCarryOverRemote {
    func source(for member: PhotoUID) async throws -> SeriesMemberSource
    /// Moves the photos to the Proton trash, where the user can restore them.
    func trashSeries(_ uids: [PhotoUID]) async throws
}

/// Reads the albums of a series photo and adds its standalone copies to the same albums.
public protocol SeriesAlbumCarryOver: Sendable {
    /// Every album that contains the photo now, shared albums included.
    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference]
    /// `albums(containing:)` for many photos with one read where the backend can. A photo in no album maps to an
    /// empty list.
    func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]]
    /// Adds the photos to an album of the account's own library. A shared album is never a valid target.
    /// Succeeds only when every photo is a member afterwards; an existing membership counts as success.
    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws
    /// `albums(containing:)` read from the server, never from a cache: a write that follows needs the current state.
    func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]]
    /// The link ID of the cover photo of each album of the account's own library that has one, by album ID.
    func ownAlbumCovers() async throws -> [String: String]
    /// Makes `uid`, a member of the album, the cover of an album of the account's own library.
    func setCover(_ uid: PhotoUID, ofOwnAlbum albumID: String) async throws
}

extension SeriesAlbumCarryOver {
    /// Backends without a membership cache read the current state with every read.
    public func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        try await albums(containing: uids)
    }

    /// Backends without album covers report none.
    public func ownAlbumCovers() async throws -> [String: String] { [:] }
    public func setCover(_ uid: PhotoUID, ofOwnAlbum albumID: String) async throws {}

    public func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        var albumsByPhoto: [PhotoUID: [SeriesAlbumReference]] = [:]
        for uid in uids where albumsByPhoto[uid] == nil {
            try Task.checkCancellation()
            albumsByPhoto[uid] = try await albums(containing: uid)
        }
        return albumsByPhoto
    }

    /// The albums of the own library that contain any of the photos, each once, in first-seen order. Shared
    /// albums are skipped: their writes cannot address a foreign volume.
    public func ownAlbumIDs(containing uids: [PhotoUID], ownVolumeID: String) async throws -> [String] {
        let albumsByPhoto = try await albums(containing: uids)
        var albumIDs: [String] = []
        for uid in uids {
            for album in albumsByPhoto[uid] ?? []
            where album.volumeID == ownVolumeID && !albumIDs.contains(album.albumID) {
                albumIDs.append(album.albumID)
            }
        }
        return albumIDs
    }
}

// MARK: - Dedupe collision rule

/// Decides how one favorite becomes a standalone photo.
///
/// The standard upload dedupe cannot be used here. The favorite's bytes already exist remotely as the
/// series member itself, so the standard rule would answer "active duplicate" and link the favorite to the
/// member that is about to move to the trash. The favorite would be lost.
///
/// Rule. The copy keeps the member's original filename. Proton's duplicate rows for that name are read, and
/// every row that belongs to the series is ignored, because the series is the source and not a copy. The
/// member's own row is ignored even when a stale membership misses it. Then:
/// 1. An active row with the same content is a standalone copy that already exists: an earlier attempt
///    committed it before the journal recorded it, or the user uploaded the same file separately. It is
///    adopted. No bytes upload, so a retry never creates a duplicate.
/// 2. A draft of this installation is an interrupted copy attempt. The upload replaces it.
/// 3. A draft of another client blocks the name. The operation stops and stays resumable.
/// 4. A trashed or deleted row with the same content does not block. The user chose to keep this favorite
///    now, so an older deletion of an identical file must not remove it from the result.
/// 5. A row with the same name and other content is another photo. The copy uploads under the same name.
public enum SeriesFavoriteCopyPolicy {
    public enum Decision: Sendable, Equatable {
        case adopt(remoteLinkID: String)
        case upload(replacingDraft: Bool)
        case blockedByForeignDraft
    }

    public static func decide(
        nameHash: String,
        contentHash: String,
        remoteItems: [RemotePhotoDuplicate],
        memberLinkID: String,
        seriesLinkIDs: Set<String>,
        currentClientUID: String?
    ) -> Decision {
        let candidates = remoteItems.filter { item in
            item.nameHash == nameHash && item.linkID != memberLinkID
                && !(item.linkID.map(seriesLinkIDs.contains) ?? false)
        }
        if let existing = candidates.first(where: { $0.linkState == .active && $0.contentHash == contentHash }),
            let linkID = existing.linkID, !linkID.isEmpty
        {
            return .adopt(remoteLinkID: linkID)
        }
        let drafts = candidates.filter { $0.linkState == .draft }
        guard !drafts.isEmpty else { return .upload(replacingDraft: false) }
        if let currentClientUID, drafts.allSatisfy({ $0.clientUID == currentClientUID }) {
            return .upload(replacingDraft: true)
        }
        return .blockedByForeignDraft
    }
}

// MARK: - Errors and progress

public enum SeriesDissolutionError: LocalizedError, Equatable {
    /// The series is not in the account's own library (a shared album, or a foreign volume).
    case notOwnLibrary
    /// The selection is empty or names a photo outside the series.
    case invalidSelection
    case alreadyRunning
    case blockedByForeignDraft(String)
    /// A confirmed copy was not active remotely even after a second copy attempt. The series is untouched.
    case copyNotConfirmed
    /// The trash request returned, but a photo of the series is still active. The operation stays pending.
    case trashNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .notOwnLibrary: L10n.string("error.series_not_own_library")
        case .invalidSelection: L10n.string("error.series_invalid_selection")
        case .alreadyRunning: L10n.string("error.series_already_running")
        case .blockedByForeignDraft(let name): L10n.string("error.series_draft_blocked \(name)")
        case .copyNotConfirmed: L10n.string("error.series_copy_not_confirmed")
        case .trashNotConfirmed: L10n.string("error.series_trash_not_confirmed")
        }
    }
}

public struct SeriesDissolutionProgress: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Copying favorite `index` (0-based) of `count`.
        case copyingFavorite(index: Int, count: Int)
        case movingSeriesToTrash
    }

    public let step: Step
    /// Monotonic 0…1 across the whole operation. Copies take the first 90 percent.
    public let fraction: Double

    public init(step: Step, fraction: Double) {
        self.step = step
        self.fraction = min(1, max(0, fraction))
    }
}

/// What `resumePending` did for one journaled series. `result` holds the standalone copies once the whole series
/// is in the trash, or the error that keeps the journal pending.
public struct SeriesDissolutionResumeOutcome: Sendable {
    public let seriesUIDs: [PhotoUID]
    public let result: Result<[PhotoUID], any Error>
}

// MARK: - Orchestrator

/// Runs "Keep Only Favorites" for a series: journal, copy every favorite, verify, carry over the favorite tag and
/// the albums, then trash the series. "Keep Everything" makes no backend call and never reaches this type.
///
/// Every entry point runs inside the account's shutdown gate. Account teardown cancels and joins the running
/// operation before the sign-out purge, so no journal file or duplicate lookup outlives the account.
public actor SeriesDissolutionOrchestrator {
    private let remote: any SeriesDissolutionRemote
    private let albums: any SeriesAlbumCarryOver
    private let uploader: any PhotoUploading
    private let duplicateChecker: any UploadDuplicateChecking
    private let journalStore: any SeriesDissolutionJournalStore
    private let admission: JoinedShutdownGate
    private let tempDirectory: URL
    private let currentClientUID: String?
    private var running: Set<PhotoUID> = []

    public init(
        remote: any SeriesDissolutionRemote,
        albums: any SeriesAlbumCarryOver,
        uploader: any PhotoUploading,
        duplicateChecker: any UploadDuplicateChecking,
        journalStore: any SeriesDissolutionJournalStore,
        admission: JoinedShutdownGate,
        tempDirectory: URL,
        currentClientUID: String?
    ) {
        self.remote = remote
        self.albums = albums
        self.uploader = uploader
        self.duplicateChecker = duplicateChecker
        self.journalStore = journalStore
        self.admission = admission
        self.tempDirectory = tempDirectory
        self.currentClientUID = currentClientUID
    }

    /// True only for a series that lies completely in the account's own photos volume. Shared albums live in
    /// a foreign volume, and the trash and upload writes address the own volume only.
    public func canDissolve(seriesUIDs: [PhotoUID]) async -> Bool {
        (try? await admission.withAdmission { [self] in await self.isOwnLibrary(seriesUIDs) }) ?? false
    }

    /// Copies every favorite into a standalone photo and then moves the whole series to the trash.
    /// Returns the standalone photos. Safe to call again after any failure or crash.
    @discardableResult
    public func keepOnlyFavorites(
        seriesMainUID: PhotoUID,
        seriesUIDs: [PhotoUID],
        favoriteUIDs: [PhotoUID],
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void = { _ in }
    ) async throws -> [PhotoUID] {
        try await admission.withAdmission { [self] in
            try await self.admittedKeepOnlyFavorites(
                seriesMainUID: seriesMainUID,
                seriesUIDs: seriesUIDs,
                favoriteUIDs: favoriteUIDs,
                onProgress: onProgress
            )
        }
    }

    /// Drops the operation of a series that the user left after a failure: Cancel, "Keep Everything" or closing
    /// the mode. Only a journal that still copies favorites is removed. The series is untouched in that phase,
    /// and copies that are already confirmed stay as standalone photos; no photo is deleted. A journal in the
    /// trash step stays, because the user's consent and the copies are final there.
    public func abandon(seriesMainUID: PhotoUID) async throws {
        try await admission.withAdmission { [self] in
            try await self.admittedAbandon(seriesMainUID: seriesMainUID)
        }
    }

    /// Finishes every interrupted operation that reached the trash step, and reports each result to the host.
    /// A failure stays journaled for the next call.
    ///
    /// A journal that still copies favorites never runs here. No user confirmed it in this session, and its
    /// selection is not final. It waits on disk: "Keep Only Favorites" on the same series continues it with the
    /// confirmed copies, and `abandon` removes it.
    public func resumePending() async throws -> [SeriesDissolutionResumeOutcome] {
        try await admission.withAdmission { [self] in
            try await self.admittedResumePending()
        }
    }

    private func isOwnLibrary(_ seriesUIDs: [PhotoUID]) async -> Bool {
        guard !seriesUIDs.isEmpty, let own = try? await remote.ownPhotosVolumeID() else { return false }
        return seriesUIDs.allSatisfy { $0.volumeID == own }
    }

    private func admittedKeepOnlyFavorites(
        seriesMainUID: PhotoUID,
        seriesUIDs: [PhotoUID],
        favoriteUIDs: [PhotoUID],
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void
    ) async throws -> [PhotoUID] {
        let existing = try journalStore.journal(forSeries: seriesMainUID)
        // A retry keeps every photo that either attempt knew. The caller's list can be older than the journal.
        let membership = Self.union(existing?.seriesUIDs ?? [], seriesUIDs)
        guard await isOwnLibrary(membership) else { throw SeriesDissolutionError.notOwnLibrary }
        let series = Set(membership)
        guard !favoriteUIDs.isEmpty, series.contains(seriesMainUID), favoriteUIDs.allSatisfy(series.contains)
        else { throw SeriesDissolutionError.invalidSelection }

        var journal =
            existing.map { Self.merging(favoriteUIDs, membership: membership, into: $0) }
            ?? SeriesDissolutionJournal(
                seriesMainUID: seriesMainUID,
                seriesUIDs: membership,
                favorites: favoriteUIDs.map { .init(memberUID: $0) }
            )
        return try await run(&journal, onProgress: onProgress)
    }

    private func admittedAbandon(seriesMainUID: PhotoUID) throws {
        guard !running.contains(seriesMainUID) else { throw SeriesDissolutionError.alreadyRunning }
        guard try journalStore.journal(forSeries: seriesMainUID)?.phase == .copyingFavorites else { return }
        try journalStore.remove(forSeries: seriesMainUID)
    }

    private func admittedResumePending() async throws -> [SeriesDissolutionResumeOutcome] {
        var outcomes: [SeriesDissolutionResumeOutcome] = []
        for var journal in try journalStore.pendingJournals() where journal.phase == .trashingSeries {
            try Task.checkCancellation()
            let result: Result<[PhotoUID], any Error>
            do {
                result = .success(try await run(&journal, onProgress: { _ in }))
            } catch {
                result = .failure(error)
            }
            outcomes.append(.init(seriesUIDs: journal.seriesUIDs, result: result))
        }
        return outcomes
    }

    private func run(
        _ journal: inout SeriesDissolutionJournal,
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void
    ) async throws -> [PhotoUID] {
        let mainUID = journal.seriesMainUID
        guard running.insert(mainUID).inserted else { throw SeriesDissolutionError.alreadyRunning }
        defer { running.remove(mainUID) }

        // The journal exists before the first remote write, so every later state is recoverable.
        try journalStore.save(journal)

        if journal.phase == .copyingFavorites {
            // The server's related photos of the main photo are authoritative. A member that the caller did not
            // know is excluded from the copy rule and moves to the trash with the rest of the series.
            try await addServerMembers(to: &journal)
            try await copyPendingFavorites(&journal, onProgress: onProgress)
            // A copy can vanish between its confirmation and now (a crash, then a manual delete). Check the
            // server, copy again once, and only then allow the trash step.
            if try await resetInactiveCopies(&journal) {
                try await copyPendingFavorites(&journal, onProgress: onProgress)
                let stillInactive = try await resetInactiveCopies(&journal)
                guard !stillInactive else { throw SeriesDissolutionError.copyNotConfirmed }
            }
            try await carryOverFavoriteAndAlbums(&journal)
            try await addServerMembers(to: &journal)
            journal.phase = .trashingSeries
            try journalStore.save(journal)
        }

        onProgress(.init(step: .movingSeriesToTrash, fraction: 0.9))
        // A resumed trash step skips photos that an earlier attempt already moved.
        let remaining = try await remote.activeUIDs(among: journal.seriesUIDs)
        if !remaining.isEmpty {
            try await remote.trashSeries(journal.seriesUIDs.filter(remaining.contains))
            // A trash request has reported success before while its photos stayed active. Only the server's
            // state ends the operation; otherwise the journal stays for the next attempt.
            guard try await remote.activeUIDs(among: journal.seriesUIDs).isEmpty else {
                throw SeriesDissolutionError.trashNotConfirmed
            }
        }
        try journalStore.remove(forSeries: mainUID)
        await duplicateChecker.invalidateCachedRemoteState()
        onProgress(.init(step: .movingSeriesToTrash, fraction: 1))
        return journal.favorites.compactMap(\.copyUID)
    }

    /// A retry may carry another selection while no series photo is trashed yet. Confirmed copies of favorites
    /// that stay selected are kept with their carried-over favorite tag and albums. A confirmed copy of a
    /// favorite that the new selection drops stays in the library: the operation never deletes a standalone
    /// photo. Once the trash step started, the recorded membership and selection are final.
    private static func merging(
        _ favoriteUIDs: [PhotoUID],
        membership: [PhotoUID],
        into journal: SeriesDissolutionJournal
    ) -> SeriesDissolutionJournal {
        guard journal.phase == .copyingFavorites else { return journal }
        var merged = journal
        merged.seriesUIDs = membership
        let confirmed = Dictionary(
            journal.favorites.filter { $0.copyUID != nil }.map { ($0.memberUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        merged.favorites = favoriteUIDs.map { confirmed[$0] ?? .init(memberUID: $0) }
        return merged
    }

    private static func union(_ first: [PhotoUID], _ second: [PhotoUID]) -> [PhotoUID] {
        var seen = Set<PhotoUID>()
        return (first + second).filter { seen.insert($0).inserted }
    }

    private func addServerMembers(to journal: inout SeriesDissolutionJournal) async throws {
        let main = journal.seriesMainUID
        let related = try await duplicateChecker.relatedPhotoLinkIDs(ofMainLinkID: main.nodeID)
        let known = Set(journal.seriesUIDs.map(\.nodeID))
        let added = related.subtracting(known).sorted().map { PhotoUID(volumeID: main.volumeID, nodeID: $0) }
        guard !added.isEmpty else { return }
        journal.seriesUIDs += added
        try journalStore.save(journal)
    }

    private func copyPendingFavorites(
        _ journal: inout SeriesDissolutionJournal,
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void
    ) async throws {
        let count = journal.favorites.count
        let seriesLinkIDs = Set(journal.seriesUIDs.map(\.nodeID))
        for index in journal.favorites.indices where journal.favorites[index].copyUID == nil {
            try Task.checkCancellation()
            let report: @Sendable (Double) -> Void = { itemFraction in
                onProgress(
                    .init(
                        step: .copyingFavorite(index: index, count: count),
                        fraction: 0.9 * (Double(index) + min(1, max(0, itemFraction))) / Double(count)
                    ))
            }
            report(0)
            journal.favorites[index].copyUID = try await copy(
                journal.favorites[index].memberUID,
                seriesLinkIDs: seriesLinkIDs,
                onProgress: report
            )
            // Persist each confirmation on its own, so a crash repeats at most the favorite in flight.
            try journalStore.save(journal)
            report(1)
        }
    }

    /// Clears the confirmation of every copy that is not an active remote photo. True when any was cleared.
    private func resetInactiveCopies(_ journal: inout SeriesDissolutionJournal) async throws -> Bool {
        let copies = journal.favorites.compactMap(\.copyUID)
        let active = try await remote.activeUIDs(among: copies)
        var didReset = false
        for index in journal.favorites.indices {
            guard let copy = journal.favorites[index].copyUID, !active.contains(copy) else { continue }
            journal.favorites[index] = .init(memberUID: journal.favorites[index].memberUID)
            didReset = true
        }
        if didReset { try journalStore.save(journal) }
        return didReset
    }

    /// Gives every copy what its source had in the library before the series leaves it: the favorite tag of its
    /// member or of the main photo, and the own albums of the main photo. The server state is read on each
    /// attempt. Each confirmed write is journaled, so a retry never adds a copy to the same album twice.
    /// Shared albums are skipped: their writes cannot address a foreign volume.
    private func carryOverFavoriteAndAlbums(_ journal: inout SeriesDissolutionJournal) async throws {
        try Task.checkCancellation()
        // Every copy is confirmed in this phase. A missing identifier would silently skip a carry-over write.
        guard journal.allFavoritesConfirmed else { throw SeriesDissolutionError.copyNotConfirmed }
        let mainUID = journal.seriesMainUID
        let favorites = try await remote.favoriteUIDs(among: journal.seriesUIDs)
        let untagged = journal.favorites.indices.filter { index in
            !journal.favorites[index].favoriteTagAdded
                && (favorites.contains(mainUID) || favorites.contains(journal.favorites[index].memberUID))
        }
        if !untagged.isEmpty {
            try await remote.markFavorite(try untagged.map { try copyUID(of: journal.favorites[$0]) })
            for index in untagged { journal.favorites[index].favoriteTagAdded = true }
            try journalStore.save(journal)
        }

        let ownAlbumIDs = try await albums.ownAlbumIDs(
            containing: [mainUID], ownVolumeID: try await remote.ownPhotosVolumeID())
        for albumID in ownAlbumIDs {
            try Task.checkCancellation()
            let missing = journal.favorites.indices.filter { !journal.favorites[$0].addedAlbumIDs.contains(albumID) }
            guard !missing.isEmpty else { continue }
            try await albums.addPhotos(
                try missing.map { try copyUID(of: journal.favorites[$0]) },
                toOwnAlbum: albumID
            )
            for index in missing { journal.favorites[index].addedAlbumIDs.append(albumID) }
            try journalStore.save(journal)
        }
    }

    private func copyUID(of favorite: SeriesDissolutionJournal.Favorite) throws -> PhotoUID {
        guard let copyUID = favorite.copyUID else { throw SeriesDissolutionError.copyNotConfirmed }
        return copyUID
    }

    /// Downloads the member's original bytes and makes them a standalone photo under the collision rule.
    /// The download takes the first half of the item's progress and the upload takes the second half.
    private func copy(
        _ member: PhotoUID,
        seriesLinkIDs: Set<String>,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoUID {
        let source = try await remote.source(for: member)
        let workDirectory = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let correctedName = ProtonPhotoNameCorrection.correctedName(for: source.filename)
        let fileURL = workDirectory.appendingPathComponent(correctedName)
        try await remote.writeOriginal(for: member, to: fileURL, onProgress: { onProgress($0 * 0.5) })

        let sha1Digest = try UploadContentSHA1.digest(ofFileAt: fileURL)
        let nameHash = try await duplicateChecker.nameHash(forCorrectedName: correctedName)
        let contentHash = try await duplicateChecker.contentHash(
            forSHA1Hex: UploadContentSHA1.hexString(digest: sha1Digest))
        let decision = SeriesFavoriteCopyPolicy.decide(
            nameHash: nameHash,
            contentHash: contentHash,
            remoteItems: try await duplicateChecker.findDuplicates(nameHashes: [nameHash]),
            memberLinkID: member.nodeID,
            seriesLinkIDs: seriesLinkIDs,
            currentClientUID: currentClientUID
        )

        switch decision {
        case .adopt(let remoteLinkID):
            return PhotoUID(volumeID: member.volumeID, nodeID: remoteLinkID)
        case .blockedByForeignDraft:
            throw SeriesDissolutionError.blockedByForeignDraft(source.filename)
        case .upload(let replacingDraft):
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let token = UUID()
            let request = PhotoUploadRequest(
                queueItemID: UUID(),
                cancellationToken: token,
                fileURL: fileURL,
                name: correctedName,
                mediaType: source.mediaType,
                fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                captureTime: source.captureTime,
                modificationDate: source.modificationDate,
                // No bursts tag and no main photo: the copy is a plain standalone photo.
                tags: [],
                additionalMetadata: source.additionalMetadata,
                expectedSHA1: sha1Digest,
                overrideExistingDraft: replacingDraft
            )
            let uploader = self.uploader
            let cancellation = BackupUploadCancellation()
            let uid: PhotoUID
            do {
                uid = try await withTaskCancellationHandler {
                    try await uploader.upload(request) { progress in
                        if progress.phase == .uploading { onProgress(0.5 + progress.fraction * 0.5) }
                    }
                } onCancel: {
                    // Task cancellation does not reach the native upload; only its token stops it.
                    Task { await cancellation.request(uploader: uploader, token: token) }
                }
            } catch {
                // Join the native cancellation, so the upload has stopped before the operation reports it.
                if Task.isCancelled { await cancellation.request(uploader: uploader, token: token) }
                throw error
            }
            await duplicateChecker.recordUploaded(contentHash: contentHash, remoteLinkID: uid.nodeID)
            return uid
        }
    }
}

/// Reads album memberships fresh for a carry-over, so an album that the person added a photo to after an earlier read
/// still receives the photo that replaces it.
public struct CurrentAlbumCarryOver: SeriesAlbumCarryOver {
    let base: any SeriesAlbumCarryOver

    public init(base: any SeriesAlbumCarryOver) {
        self.base = base
    }

    public func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        try await base.currentAlbums(containing: [uid])[uid] ?? []
    }

    public func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        try await base.currentAlbums(containing: uids)
    }

    public func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        try await base.currentAlbums(containing: uids)
    }

    public func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        try await base.addPhotos(uids, toOwnAlbum: albumID)
    }

    public func ownAlbumCovers() async throws -> [String: String] { try await base.ownAlbumCovers() }

    public func setCover(_ uid: PhotoUID, ofOwnAlbum albumID: String) async throws {
        try await base.setCover(uid, ofOwnAlbum: albumID)
    }
}
