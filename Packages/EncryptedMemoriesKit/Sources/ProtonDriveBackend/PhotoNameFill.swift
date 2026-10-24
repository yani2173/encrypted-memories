import Foundation
import PhotosCore
import UploadCore

/// Fills the file name index from `links/fetch_metadata` responses.
///
/// The timeline metadata pass hands over the names of the links it read anyway. A library that finished its pass
/// before names were kept gets one backfill: the photos without a stored name, 150 per request, at maintenance
/// priority. Each batch commits on its own, so an app end loses at most the batch in flight.
enum PhotoNameFill {
    struct Outcome: Equatable, Sendable {
        var requests = 0
        var recorded = 0
        /// Names not written because a rename or removal arrived while their batch was read.
        var superseded = 0
        /// The backfill stopped before it covered every photo: the runtime withdrew permission.
        var deferred = false
    }

    /// The names of the requested links of one response, by photo. A name that does not decrypt is recorded empty,
    /// so that photo is not requested again until an event changes it.
    static func names(
        in links: [AlbumPhotoLinkBody], requested: Set<String>, volumeID: String, decrypt: (String) -> String?
    ) -> [PhotoUID: String] {
        var names: [PhotoUID: String] = [:]
        for link in links {
            guard let linkID = link.linkID, requested.contains(linkID) else { continue }
            names[PhotoUID(volumeID: volumeID, nodeID: linkID)] = link.name.flatMap(decrypt) ?? ""
        }
        return names
    }

    /// The backfill reads only while the app is active in the foreground on a reachable network that is neither
    /// constrained (Low Data Mode) nor expensive (cellular or a personal hotspot).
    static func permits(_ runtime: LibraryRuntimeSnapshot) -> Bool {
        let network = runtime.network
        return runtime.executionOpportunity == .foregroundActive && network.isDetermined && network.isReachable
            && !network.isConstrained && !network.isExpensive
    }

    /// Reads the names of the given photos that have no stored name. It stops without an error when `permits`
    /// turns false and continues in a later pass. `nameKey` is asked once, before the first request, and only when
    /// a name is missing; nil (the key is unavailable) ends the backfill for this pass.
    static func backfill(
        nodeIDs: [String],
        volumeID: String,
        store: PhotoNameStore,
        permits: () -> Bool,
        nameKey: () async throws -> ((String) -> String?)?,
        fetch: ([String]) async throws -> [AlbumPhotoLinkBody],
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        var outcome = Outcome()
        guard let recorded = store.recordedNodeIDs(volumeID: volumeID) else { return outcome }
        let missing = Array(Set(nodeIDs).subtracting(recorded)).sorted()
        let size = UploadDedupePipeline.protonDuplicateBatchSize
        var decrypt: ((String) -> String?)?
        for start in stride(from: 0, to: missing.count, by: size) {
            try Task.checkCancellation()
            guard permits() else {
                outcome.deferred = true
                return outcome
            }
            if decrypt == nil { decrypt = try await nameKey() }
            guard let decrypt else { return outcome }
            let batch = Array(missing[start..<min(start + size, missing.count)])
            let token = store.forgetToken
            let links = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await fetch(batch)
            }
            outcome.requests += 1
            try Task.checkCancellation()
            var names = Self.names(in: links, requested: Set(batch), volumeID: volumeID, decrypt: decrypt)
            // A photo that the response lacks has no readable name now; an event or rename brings it back.
            for nodeID in batch where names[PhotoUID(volumeID: volumeID, nodeID: nodeID)] == nil {
                names[PhotoUID(volumeID: volumeID, nodeID: nodeID)] = ""
            }
            switch store.record(names, unlessForgottenSince: token) {
            case .written: outcome.recorded += names.count
            // A rename or removal arrived during the read; the batch stays without rows and the next backfill reads it.
            case .superseded: outcome.superseded += names.count
            case .failed: throw PhotoNameFillError.storeUnavailable
            }
            await Task.yield()
        }
        return outcome
    }
}

enum PhotoNameFillError: Error {
    case storeUnavailable
}

/// Runs the name backfill as its own task, after the metadata pass that scheduled it returned. The pass therefore
/// publishes its page results, and a newer inventory starts its pass, without waiting for name reads. A newer backfill
/// cancels the running one and starts after it ended; nothing starts after `close()`.
final class PhotoNameBackfillQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var closed = false

    func schedule(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard !closed else { return }
            let previous = task
            previous?.cancel()
            task = Task(priority: .background) {
                await previous?.value
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    /// Cancels the running backfill and admits no new one.
    func close() {
        let current = lock.withLock {
            closed = true
            return task
        }
        current?.cancel()
    }

    /// Returns when the last scheduled backfill ended.
    func wait() async {
        let current = lock.withLock { task }
        await current?.value
    }
}
