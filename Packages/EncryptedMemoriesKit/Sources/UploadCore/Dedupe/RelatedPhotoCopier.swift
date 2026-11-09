import Foundation
import PhotosCore

/// Metadata of a source file that becomes a standalone copy. Both the series dissolution (a series member) and the
/// revert to original (the hidden original file) conform, so one copy helper serves both features without duplication.
public protocol RelatedPhotoCopySourceInfo: Sendable {
    var filename: String { get }
    var mediaType: String { get }
    var captureTime: Date { get }
    var modificationDate: Date { get }
    var additionalMetadata: [PhotoUploadAdditionalMetadata] { get }
}

/// A series member's metadata conforms to the copy source rule.
extension SeriesMemberSource: RelatedPhotoCopySourceInfo {}

/// One error from the shared copy helper that each caller maps to its own domain error.
public enum RelatedPhotoCopyError: Error, Equatable {
    /// Another client's draft occupies the upload name. The operation stays resumable. `occupiedName` is the
    /// upload name that the draft blocks; `sourceFilename` is the file the copy was made from, for messages
    /// that name the person's file.
    case blockedByForeignDraft(occupiedName: String, sourceFilename: String)
}

/// The hidden original's metadata conforms to the copy source rule.
extension EditedOriginalSource: RelatedPhotoCopySourceInfo {}

/// Downloads a source file and makes it a standalone photo under the copy rule that ignores the source compound.
///
/// The upload dedupe rule would see the source itself as an active duplicate and link the copy to a photo that is
/// about to leave the library. `RelatedPhotoCopyPolicy.decide` decides adoption or upload instead. Every identity
/// read and the upload happen here, so the series dissolution and the revert to original share one path.
public struct RelatedPhotoCopier: Sendable {
    private let uploader: any PhotoUploading
    private let duplicateChecker: any UploadDuplicateChecking
    private let provider: any OriginalFileProvider
    private let tempDirectory: URL
    private let currentClientUID: String?

    public init(
        uploader: any PhotoUploading,
        duplicateChecker: any UploadDuplicateChecking,
        provider: any OriginalFileProvider,
        tempDirectory: URL,
        currentClientUID: String?
    ) {
        self.uploader = uploader
        self.duplicateChecker = duplicateChecker
        self.provider = provider
        self.tempDirectory = tempDirectory
        self.currentClientUID = currentClientUID
    }

    /// Downloads `sourceUID` into a fresh work directory, computes its content identity, decides adoption or upload
    /// via `RelatedPhotoCopyPolicy.decide`, and uploads under `uploadName` with `extraMetadata` appended to the
    /// source's additional metadata. The download takes the first half of the reported progress and the upload the
    /// second half. A retry repeats no write twice.
    public func makeStandaloneCopy(
        sourceUID: PhotoUID,
        source: any RelatedPhotoCopySourceInfo,
        uploadName: String,
        extraMetadata: [PhotoUploadAdditionalMetadata],
        sourceLinkID: String,
        compoundLinkIDs: Set<String>,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoUID {
        let workDirectory = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let fileURL = workDirectory.appendingPathComponent(uploadName)
        try await provider.writeOriginal(for: sourceUID, to: fileURL, onProgress: { onProgress($0 * 0.5) })

        let sha1Digest = try UploadContentSHA1.digest(ofFileAt: fileURL)
        let nameHash = try await duplicateChecker.nameHash(forCorrectedName: uploadName)
        let contentHash = try await duplicateChecker.contentHash(
            forSHA1Hex: UploadContentSHA1.hexString(digest: sha1Digest))
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: nameHash,
            contentHash: contentHash,
            remoteItems: try await duplicateChecker.findDuplicates(nameHashes: [nameHash]),
            sourceLinkID: sourceLinkID,
            compoundLinkIDs: compoundLinkIDs,
            currentClientUID: currentClientUID
        )

        switch decision {
        case .adopt(let remoteLinkID):
            return PhotoUID(volumeID: sourceUID.volumeID, nodeID: remoteLinkID)
        case .blockedByForeignDraft:
            // The blocked name is the upload name that the foreign draft occupies; the source's filename rides
            // along for callers whose message names the person's file.
            throw RelatedPhotoCopyError.blockedByForeignDraft(
                occupiedName: uploadName, sourceFilename: source.filename)
        case .upload(let replacingDraft):
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let token = UUID()
            var request = PhotoUploadRequest(
                queueItemID: UUID(),
                cancellationToken: token,
                fileURL: fileURL,
                name: uploadName,
                mediaType: source.mediaType,
                fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                captureTime: source.captureTime,
                modificationDate: source.modificationDate,
                // No bursts tag and no main photo: the copy is a plain standalone photo.
                tags: [],
                additionalMetadata: source.additionalMetadata + extraMetadata,
                expectedSHA1: sha1Digest,
                overrideExistingDraft: replacingDraft
            )
            let uploader = self.uploader
            let reservation = try await uploader.reserveNetwork(allowsExpensiveNetwork: request.allowsExpensiveNetwork)
            defer { reservation.release() }
            request.networkReservation = reservation
            let reservedRequest = request
            let cancellation = BackupUploadCancellation()
            let uid: PhotoUID
            do {
                uid = try await withTaskCancellationHandler {
                    try await uploader.upload(reservedRequest) { progress in
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
