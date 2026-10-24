#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import CoreGraphics
    import CryptoKit
    import MediaDecodingCore
    import Foundation
    import PhotosCore
    import UploadCore

    /// Replaces only the PhotoKit input boundary. Catalog, queue and runner remain unchanged.
    enum UpgradeTestPhotoLibrary {
        static let date = Date(timeIntervalSince1970: 1_720_100_000)

        static func info(_ id: Int) -> PhotoBackupAssetInfo {
            PhotoBackupAssetInfo(
                localIdentifier: "asset-\(id)", creationDate: date, modificationDate: date,
                pixelWidth: 32, pixelHeight: 32, durationSeconds: 0, isLivePhoto: false, isVideo: false,
                resources: [.init(role: .originalPhoto, originalFilename: "Synthetic-\(id).png", mimeType: "image/png")]
            )
        }

        static func infoChunks(
            identifiers: [String]?, startOffset: Int, chunkSize: Int
        ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            let rows = (0..<8).map(info).filter { identifiers?.contains($0.localIdentifier) ?? true }
            return AsyncThrowingStream { continuation in
                let size = max(1, chunkSize)
                for offset in stride(from: max(0, startOffset), to: rows.count, by: size) {
                    continuation.yield(Array(rows[offset..<min(rows.count, offset + size)]))
                }
                continuation.finish()
            }
        }

        static func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<PhotoLibraryIdentifierChunk, any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(
                    PhotoLibraryIdentifierChunk(identifiers: (0..<8).map { "asset-\($0)" }, totalCount: 8))
                continuation.finish()
            }
        }

        static func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
            var result: [PhotoUID: DecodedThumbnail] = [:]
            for uid in uids where uid.localPendingNamespace == .photoLibrary {
                guard !Task.isCancelled else { return result }
                do {
                    let bytes = try await UpgradeTestProbe.request("thumbnail/\(uid.nodeID)")
                    guard let decoded = ThumbnailImageDecoder.downsample(bytes, maxPixelSize: maxPixelSize) else {
                        fatalError("The synthetic local thumbnail did not decode")
                    }
                    result[uid] = decoded
                } catch {
                    // PhotoKit also returns no image when the feed cancels a retired pending identity.
                    if Task.isCancelled,
                        error is CancellationError || (error as? URLError)?.code == .cancelled
                    {
                        return result
                    }
                    let failure = error as NSError
                    fatalError("The synthetic local thumbnail request failed: \(failure.domain) (\(failure.code))")
                }
            }
            return result
        }

        static func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            guard let id = Int(entry.source.identifier.dropFirst(6)), (0..<8).contains(id),
                let candidate = PhotoBackupAssetPlanner.candidate(for: info(id))
            else { throw UploadError.backend("Unexpected synthetic photo") }
            let bytes = try await UpgradeTestProbe.request("thumbnail/asset-\(id)")
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UpgradeFixtureExports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("asset-\(id).png")
            try bytes.write(to: file, options: .atomic)
            let descriptor = UploadResourceDescriptor(
                source: candidate.snapshot.source, fileURL: file, filename: "Synthetic-\(id).png",
                fileSize: Int64(bytes.count), modificationDate: date,
                precomputedSHA1Digest: Data(Insecure.SHA1.hash(data: bytes)))
            return BackupResolvedResource(
                candidate: candidate, descriptor: descriptor, mediaType: "image/png", captureDate: date, secondaries: []
            )
        }
    }
#endif
