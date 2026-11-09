import Foundation
import MediaByteCache
import MediaCache
import PhotosCore

/// Small fakes that viewer model tests share: a thumbnail loader that delivers nothing, a media provider that fails, and
/// a gate that holds a call open.
struct MetadataEmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

struct MetadataFailingMediaProvider: FullMediaProvider {
    func preview(for uid: PhotoUID) async throws -> Data { throw MetadataTestError.unavailable }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw MetadataTestError.unavailable
    }
}

enum MetadataTestError: Error {
    case unavailable
}

/// Holds a call open until the test lets it go. The wait for the start is bounded, so a call that never starts fails
/// an assertion and does not hang the suite.
actor Gate {
    private var entered = false
    private var isOpen = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters = []
    }
}
