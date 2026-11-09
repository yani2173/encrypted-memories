import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerFeature
import PhotosCore
import XCTest

@testable import PhotoViewerCore

/// The Mac viewer model decides when "Revert to Original…" is available and what a confirmation does. These tests drive
/// the real model with a lookup that answers at once, so the wiring of the three inputs (a proven original, the viewer's
/// mutation action, a reverter) and of the viewer's teardown has an assertion that fails when it breaks.
@MainActor
final class PhotoViewerModelRevertWiringTests: XCTestCase {
    private let main = PhotoItem(
        uid: PhotoUID(volumeID: "own", nodeID: "edited"), captureTime: Date(timeIntervalSince1970: 1),
        mediaType: "image/jpeg")
    private let original = PhotoItem(
        uid: PhotoUID(volumeID: "own", nodeID: "original"), captureTime: Date(timeIntervalSince1970: 1),
        mediaType: "image/heic")

    private func makeModel(
        mutationAction: ViewerMutationAction?, reverter: (any EditedPhotoReverting)?, provesOriginal: Bool = true,
        onReverted: (@MainActor @Sendable (PhotoItem) async -> Void)? = nil
    ) async -> PhotoViewerModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("revert-wiring-\(UUID().uuidString)", isDirectory: true)
        let lookup = EditedPhotoOriginalLookup(
            sleep: { _ in }, admits: { true }, changes: { AsyncStream { $0.finish() } })
        let model = PhotoViewerModel(
            items: [main], index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "revert-wiring-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()),
            media: MetadataFailingMediaProvider(),
            editedOriginalProvider: StaticOriginals(answer: provesOriginal ? original : nil),
            editedPhotoReverter: reverter, mutationAction: mutationAction, onReverted: onReverted,
            editedOriginalLookup: lookup)
        model.start()
        await lookup.pending?.value
        return model
    }

    func testTheCommandIsAvailableOnlyInTheOwnLibraryWithAProvenOriginalAndAReverter() async {
        let reverter = SpyReverter()
        let own = await makeModel(mutationAction: .moveToTrash, reverter: reverter)
        XCTAssertTrue(own.canRevertToOriginal)
        own.stop()

        for action: ViewerMutationAction? in [.restore, .saveToLibrary, nil] {
            let model = await makeModel(mutationAction: action, reverter: reverter)
            XCTAssertTrue(model.canShowOriginal, "the original is proven, so only the context blocks the command")
            XCTAssertFalse(model.canRevertToOriginal, "no revert in the context \(String(describing: action))")
            model.requestRevertToOriginal()
            XCTAssertEqual(model.revert.phase, .idle)
            model.stop()
        }

        let withoutReverter = await makeModel(mutationAction: .moveToTrash, reverter: nil)
        XCTAssertFalse(withoutReverter.canRevertToOriginal)
        withoutReverter.stop()

        let unproven = await makeModel(mutationAction: .moveToTrash, reverter: reverter, provesOriginal: false)
        XCTAssertFalse(unproven.canShowOriginal)
        XCTAssertFalse(unproven.canRevertToOriginal)
        unproven.stop()
    }

    func testAConfirmationRevertsTheShownPhotoToItsFoundOriginalThenRunsTheHostWork() async {
        let reverter = SpyReverter()
        let events = Events()
        let model = await makeModel(
            mutationAction: .moveToTrash, reverter: reverter,
            onReverted: { photo in await events.add("reverted \(photo.uid.nodeID)") })
        model.requestRevertToOriginal()
        XCTAssertEqual(model.revert.phase, .confirming)

        model.confirmRevertToOriginal(onSuccess: { Task { await events.add("closed") } })
        await model.revert.current?.value
        for _ in 0..<20 where await events.count < 2 { await Task.yield() }

        let calls = await reverter.calls
        XCTAssertEqual(calls.map(\.main.uid), [main.uid])
        XCTAssertEqual(calls.map(\.original.uid), [original.uid])
        let order = await events.all
        XCTAssertEqual(order, ["reverted edited", "closed"])
        model.stop()
    }

    /// The viewer closes while the revert runs. `stop()` is what the view calls from `onDisappear`: the viewer's close
    /// callback is dropped, and the host work still runs.
    func testClosingTheViewerDropsTheCloseCallbackButNotTheHostWork() async {
        let gate = Gate()
        let reverter = SpyReverter(gate: gate)
        let events = Events()
        let model = await makeModel(
            mutationAction: .moveToTrash, reverter: reverter,
            onReverted: { _ in await events.add("reverted") })
        model.requestRevertToOriginal()
        model.confirmRevertToOriginal(onSuccess: { [model] in
            _ = model
            Task { await events.add("closed") }
        })
        let started = await gate.waitUntilEntered()
        XCTAssertTrue(started, "the revert did not start")

        model.stop()
        await gate.open()
        await model.revert.current?.value
        for _ in 0..<20 { await Task.yield() }

        let order = await events.all
        XCTAssertEqual(order, ["reverted"], "the host work ran and nothing closed the next viewer")
    }
}

private struct StaticOriginals: EditedPhotoOriginalProviding {
    let answer: PhotoItem?
    func editedOriginal(of item: PhotoItem) async throws -> PhotoItem? { answer }
}

private actor SpyReverter: EditedPhotoReverting {
    struct Call {
        let main: PhotoItem
        let original: PhotoItem
    }
    private(set) var calls: [Call] = []
    private let gate: Gate?

    init(gate: Gate? = nil) { self.gate = gate }

    func revertToOriginal(of main: PhotoItem, original: PhotoItem) async throws {
        calls.append(Call(main: main, original: original))
        await gate?.wait()
    }
}

private actor Events {
    private(set) var all: [String] = []
    var count: Int { all.count }
    func add(_ event: String) { all.append(event) }
}
