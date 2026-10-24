import Foundation
import PhotoViewerCore
import Testing

@Suite("Viewer Info publication")
@MainActor
struct ViewerInfoPublicationTests {
    @Test(arguments: [true, false])
    func metadataIsShownWhileTheAlbumReadIsStillPending(metadataSucceeds: Bool) async throws {
        let albums = Gate()
        let log = PublicationLog()
        let run = Task { @MainActor in
            await ViewerInfoPublication.run(
                metadata: { metadataSucceeds ? "metadata" : "metadata failed" },
                memberships: {
                    await albums.wait()
                    return ["Holiday"]
                },
                isCurrent: { true },
                publishMetadata: { log.append($0) },
                publishMemberships: { log.append($0.joined()) }
            )
        }
        try await waitUntil { log.values.count == 1 }
        #expect(log.values == [metadataSucceeds ? "metadata" : "metadata failed"])
        await albums.open()
        await run.value
        #expect(log.values.last == "Holiday")
        #expect(log.values.count == 2)
    }

    @Test func albumsArrivingFirstDoNotWaitForTheMetadataEither() async throws {
        let metadata = Gate()
        let log = PublicationLog()
        let run = Task { @MainActor in
            await ViewerInfoPublication.run(
                metadata: {
                    await metadata.wait()
                    return "metadata"
                },
                memberships: { ["Holiday"] },
                isCurrent: { true },
                publishMetadata: { log.append($0) },
                publishMemberships: { log.append($0.joined()) }
            )
        }
        try await waitUntil { log.values == ["Holiday"] }
        await metadata.open()
        await run.value
        #expect(log.values == ["Holiday", "metadata"])
    }

    @Test func aResultForAPhotoThatIsNoLongerShownIsDropped() async throws {
        let albums = Gate()
        let log = PublicationLog()
        let current = PublicationLog()
        let run = Task { @MainActor in
            await ViewerInfoPublication.run(
                metadata: { "metadata" },
                memberships: {
                    await albums.wait()
                    return ["Holiday"]
                },
                isCurrent: { current.values.isEmpty },
                publishMetadata: { log.append($0) },
                publishMemberships: { log.append($0.joined()) }
            )
        }
        try await waitUntil { log.values == ["metadata"] }
        // The person swiped to the next photo before the album read ended.
        current.append("moved")
        await albums.open()
        await run.value
        #expect(log.values == ["metadata"])
    }

    @Test func aCancelledRunPublishesNothingMore() async throws {
        let albums = Gate()
        let log = PublicationLog()
        let run = Task { @MainActor in
            await ViewerInfoPublication.run(
                metadata: { "metadata" },
                memberships: {
                    await albums.wait()
                    return ["Holiday"]
                },
                isCurrent: { true },
                publishMetadata: { log.append($0) },
                publishMemberships: { log.append($0.joined()) }
            )
        }
        try await waitUntil { log.values == ["metadata"] }
        // A retry or a privacy change replaces the task, which cancels this one.
        run.cancel()
        await albums.open()
        await run.value
        #expect(log.values == ["metadata"])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition did not become true before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class PublicationLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
