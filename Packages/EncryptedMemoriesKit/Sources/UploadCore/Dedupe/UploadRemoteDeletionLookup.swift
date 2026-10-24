import Foundation
import PhotosCore

public enum UploadRemoteDeletionState: Sendable, Equatable {
    case trashed
}

public struct UploadLinkStateSnapshot: Sendable {
    public let states: [String: Int]
    public let complete: Bool

    public init(states: [String: Int], complete: Bool) {
        self.states = states
        self.complete = complete
    }
}

/// Missing metadata remains unknown. The available name-scoped duplicate endpoint and active-only content index
/// cannot prove absence across all states for a content hash, so neither authorizes a permanent-deletion inference.
public enum UploadRemoteDeletionLookup {
    public static func states(
        for linkIDs: [String], checker: any UploadDuplicateChecking
    ) async throws -> [String: UploadRemoteDeletionState] {
        var result: [String: UploadRemoteDeletionState] = [:]
        let size = UploadDedupePipeline.protonDuplicateBatchSize
        for start in stride(from: 0, to: linkIDs.count, by: size) {
            try Task.checkCancellation()
            let chunk = Array(Set(linkIDs[start..<min(start + size, linkIDs.count)])).sorted()
            let metadata: UploadLinkStateSnapshot
            do {
                metadata = try await checker.linkStateSnapshot(of: chunk)
            } catch {
                try Task.checkCancellation()
                if UploadError.isCancellation(error) { throw error }
                PhotoDiagnostics.shared.increment("albumSync.deletionMetadataUnavailable")
                continue
            }
            try Task.checkCancellation()
            guard metadata.complete else {
                PhotoDiagnostics.shared.increment("albumSync.deletionMetadataPartial")
                continue
            }
            for linkID in chunk where metadata.states[linkID] == 2 {
                result[linkID] = .trashed
            }
        }
        return result
    }
}

public extension UploadDuplicateChecking {
    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot {
        UploadLinkStateSnapshot(states: [:], complete: false)
    }
}
