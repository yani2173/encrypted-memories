import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite
struct TimelineTagEnrichmentTests {
    @Test
    func startsVideoLivePhotoAndBurstRequestsBeforeAwaitingAnyResult() async {
        let gate = TagStartGate(expected: 3)
        let enrichment = await TimelineTagEnrichmentLoader.load { tag, onPage in
            await gate.arrive(tag.rawValue)
            try await onPage([])
        }

        #expect(
            await gate.startedTags()
                == Set([PhotoTag.videos.rawValue, PhotoTag.livePhotos.rawValue, PhotoTag.bursts.rawValue]))
        #expect(enrichment.videos.value?.isEmpty == true)
        #expect(enrichment.livePhotos.value?.isEmpty == true)
        #expect(enrichment.bursts.value?.isEmpty == true)
        #expect(!enrichment.wasCancelled)
    }

    @Test
    func reducesTagPagesIntoOnlyTheRequiredIndexes() async {
        let enrichment = await TimelineTagEnrichmentLoader.load { tag, onPage in
            switch tag {
            case .videos:
                try await onPage([entry("video-1")])
                try await onPage([entry("video-2")])
            case .livePhotos:
                try await onPage([
                    entry("live-1", related: ["plist-1", "motion-1"]),
                    entry("still", related: []),
                ])
            case .bursts:
                try await onPage([entry("burst-1"), entry("burst-2")])
            default:
                break
            }
        }

        #expect(enrichment.videos.value == Set(["video-1", "video-2"]))
        #expect(
            enrichment.livePhotos.value == ["live-1": ["plist-1", "motion-1"], "still": []],
            "every related file in listing order, so the motion is not the newest one")
        #expect(enrichment.bursts.value?.map(\.linkID) == ["burst-1", "burst-2"])
    }

    private func entry(_ linkID: String, related: [String] = []) -> PhotosListEntry {
        PhotosListEntry(
            linkID: linkID,
            captureTime: 0,
            tags: [],
            relatedPhotos: related.map(PhotosListEntry.Related.init(linkID:))
        )
    }
}

private actor TagStartGate {
    private let expected: Int
    private var tags: Set<Int> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arrive(_ tag: Int) async {
        tags.insert(tag)
        guard tags.count < expected else {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func startedTags() -> Set<Int> {
        tags
    }
}
