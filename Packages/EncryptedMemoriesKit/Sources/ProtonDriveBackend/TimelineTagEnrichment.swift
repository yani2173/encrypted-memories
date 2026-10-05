import PhotosCore

struct TimelineTagFetchResult<Value: Sendable>: Sendable {
    let value: Value?
    let errorDescription: String?
    let wasCancelled: Bool

    static func success(_ value: Value) -> Self {
        Self(value: value, errorDescription: nil, wasCancelled: false)
    }

    static func failure(_ error: Error) -> Self {
        Self(value: nil, errorDescription: String(describing: error), wasCancelled: false)
    }

    static var cancelled: Self {
        Self(value: nil, errorDescription: nil, wasCancelled: true)
    }
}

struct TimelineTagEnrichment: Sendable {
    let videos: TimelineTagFetchResult<Set<String>>
    /// The related files of each Live Photo in listing order, by link ID.
    let livePhotos: TimelineTagFetchResult<[String: [String]]>
    let bursts: TimelineTagFetchResult<[PhotosListEntry]>

    var wasCancelled: Bool {
        videos.wasCancelled || livePhotos.wasCancelled || bursts.wasCancelled
    }
}

private actor TimelineTagPageAccumulator<Value: Sendable> {
    private var value: Value
    private let merge: @Sendable (inout Value, [PhotosListEntry]) -> Void

    init(value: Value, merge: @escaping @Sendable (inout Value, [PhotosListEntry]) -> Void) {
        self.value = value
        self.merge = merge
    }

    func append(_ page: [PhotosListEntry]) {
        merge(&value, page)
    }

    func result() -> Value {
        value
    }
}

enum TimelineTagEnrichmentLoader {
    typealias PageFetcher =
        @Sendable (
            PhotosCore.PhotoTag,
            @escaping @Sendable ([PhotosListEntry]) async throws -> Void
        ) async throws -> Void

    static func load(
        fetchPages: @escaping PageFetcher
    ) async -> TimelineTagEnrichment {
        async let videos: TimelineTagFetchResult<Set<String>> = fetchOne(
            tag: .videos,
            initialValue: Set<String>(),
            merge: { result, page in
                result.formUnion(page.lazy.map(\.linkID))
            },
            fetchPages: fetchPages
        )
        async let livePhotos: TimelineTagFetchResult<[String: [String]]> = fetchOne(
            tag: .livePhotos,
            initialValue: [:],
            merge: { result, page in
                for entry in page where result[entry.linkID] == nil {
                    result[entry.linkID] = entry.relatedLinkIDs
                }
            },
            fetchPages: fetchPages
        )
        async let bursts: TimelineTagFetchResult<[PhotosListEntry]> = fetchOne(
            tag: .bursts,
            initialValue: [],
            merge: { result, page in
                result.append(contentsOf: page)
            },
            fetchPages: fetchPages
        )
        let (videoResult, livePhotoResult, burstResult) = await (videos, livePhotos, bursts)
        return TimelineTagEnrichment(
            videos: videoResult,
            livePhotos: livePhotoResult,
            bursts: burstResult
        )
    }

    private static func fetchOne<Value: Sendable>(
        tag: PhotosCore.PhotoTag,
        initialValue: Value,
        merge: @escaping @Sendable (inout Value, [PhotosListEntry]) -> Void,
        fetchPages: @escaping PageFetcher
    ) async -> TimelineTagFetchResult<Value> {
        let accumulator = TimelineTagPageAccumulator(value: initialValue, merge: merge)
        do {
            try Task.checkCancellation()
            try await fetchPages(tag) { page in
                try Task.checkCancellation()
                await accumulator.append(page)
            }
            try Task.checkCancellation()
            return .success(await accumulator.result())
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error)
        }
    }
}
