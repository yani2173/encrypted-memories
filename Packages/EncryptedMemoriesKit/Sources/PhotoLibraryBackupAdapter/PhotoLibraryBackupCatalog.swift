import Foundation
import Photos
import UploadCore

/// Photo-library source for the shared backup engine: streams `UploadBackupAssetCandidate`s from
/// a cheap metadata-only enumeration (no resource bytes are touched). Newest-first so the first
/// backup pass delivers user-visible value immediately; remote timeline placement still follows
/// capture time, which travels on each upload.
public struct PhotoLibraryBackupCatalog: UploadBackupAssetCatalog {
    /// nil = whole library; otherwise a targeted incremental scan (persistent-change results).
    public let localIdentifiers: [String]?
    /// Assets handed to the mapper per autorelease drain - bounds transient PhotoKit memory.
    public let chunkSize: Int

    public init(localIdentifiers: [String]? = nil, chunkSize: Int = 200) {
        self.localIdentifiers = localIdentifiers
        self.chunkSize = max(1, chunkSize)
    }

    public func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        let identifiers = localIdentifiers
        let chunkSize = chunkSize
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let fetchResult = PhotoKitAssetMapper.fetchAssets(identifiers: identifiers)

                let total = fetchResult.count
                var index = 0
                while index < total {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let upperBound = min(index + chunkSize, total)
                    autoreleasepool {
                        let assets = (index..<upperBound).map { fetchResult.object(at: $0) }
                        for info in PhotoKitAssetMapper.infos(for: assets) {
                            if let candidate = PhotoBackupAssetPlanner.candidate(for: info) {
                                continuation.yield(candidate)
                            }
                        }
                    }
                    index = upperBound
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
