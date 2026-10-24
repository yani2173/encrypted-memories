import Foundation
import ImageIO
import PhotoViewerCore
import PhotosCore
import Testing
import UniformTypeIdentifiers

@testable import EncryptedMemoriesMobile

@Suite @MainActor
struct MobileShareExportTests {
    @Test func discardedPresentationOwnerDoesNotRetainExportOrLeavePlaintext() async throws {
        let backend = ShareExportTestBackend()
        var owner: MobileGridSelectionController? = MobileGridSelectionController()
        weak var weakOwner = owner
        owner?.startShare(items: [item("blocked")], backend: backend)
        await backend.waitUntilBlocked()
        let directory = try #require(await backend.directory(for: "blocked"))
        owner = nil
        #expect(weakOwner == nil)
        await backend.release()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: directory.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // Avoid leaving the RED fixture's plaintext behind.
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func payloadCopiesKeepFilesUntilTheLastPresentationOwnerReleasesThem() async throws {
        let url = try #require(await MobileMediaExporter.exportSupportReport(Data("owned".utf8)))
        var original: MobileSharePayload? = MobileSharePayload(urls: [url])
        var presenter = original
        original = nil
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(presenter?.urls == [url])
        presenter = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        MobileMediaExporter.cleanup([url])
    }

    @Test func partialShareTransfersFileOwnershipToThePresenter() async throws {
        let url = try #require(await MobileMediaExporter.exportSupportReport(Data("partial".utf8)))
        var partial: MobilePartialShare? = MobilePartialShare(urls: [url], failed: 1)
        var payload: MobileSharePayload? = MobileSharePayload(
            urls: [url], fileOwnership: try #require(partial?.fileOwnership))
        partial = nil
        #expect(payload?.urls == [url])
        #expect(FileManager.default.fileExists(atPath: url.path))
        payload = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func item(_ id: String) -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "share-tests", nodeID: id), captureTime: Date(), mediaType: "image/jpeg")
    }

    @Test func concurrentShareJobsKeepTheirFilesAndSupportReport() async throws {
        // Synthetic JPEG bytes are not decodable; this test keeps location to test the share files.
        try await SharingLocationPreferenceLease.with(storedValue: false) {
            let backend = ShareExportTestBackend()
            let runtime = LibraryRuntimeState()
            let support = try #require(await MobileMediaExporter.exportSupportReport(Data("support".utf8)))
            defer { MobileMediaExporter.cleanup([support]) }
            let first = Task {
                await MobileMediaExporter.exportOriginals([item("blocked")], backend: backend, runtimeState: runtime)
            }
            await backend.waitUntilBlocked()
            #expect(runtime.snapshot().activeUserTransferCount == 1)
            let second = await MobileMediaExporter.exportOriginals([item("second")], backend: backend)
            #expect(second.urls.count == 1)
            #expect(second.urls.first?.deletingLastPathComponent() != support.deletingLastPathComponent())
            MobileMediaExporter.cleanup(second.urls)
            await backend.release()
            let result = await first.value
            #expect(runtime.snapshot().activeUserTransferCount == 0)
            defer { MobileMediaExporter.cleanup(result.urls) }
            #expect(result.urls.count == 1)
            #expect(result.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            #expect(FileManager.default.fileExists(atPath: support.path))
        }
    }

    @Test func shareStopsBeforeTheDeviceRunsFull() async throws {
        // Synthetic JPEG bytes are not decodable; this test keeps location to test the share files.
        try await SharingLocationPreferenceLease.with(storedValue: false) {
            let backend = ShareExportTestBackend()
            let full = await MobileMediaExporter.exportOriginals(
                [item("a"), item("b")], backend: backend, availableCapacity: { _ in 0 })
            #expect(full.urls.isEmpty)
            #expect(full.failed == 2)
            #expect(full.ranOutOfSpace)
            #expect(await backend.directory(for: "a") == nil, "no download starts without room")

            var remaining: Int64 = 1 << 40
            let partial = await MobileMediaExporter.exportOriginals(
                [item("c"), item("d"), item("e")], backend: backend,
                availableCapacity: { _ in
                    defer { remaining = 0 }
                    return remaining
                })
            defer { MobileMediaExporter.cleanup(partial.urls) }
            #expect(partial.urls.count == 1)
            #expect(partial.failed == 2)
            #expect(partial.ranOutOfSpace)
        }
    }

    @Test(arguments: [nil, false] as [Bool?])
    func shareOfARealPhotoFollowsTheLocationPreference(storedValue: Bool?) async throws {
        try await SharingLocationPreferenceLease.with(storedValue: storedValue) {
            let original = try LocatedShareTestImage.makeLocatedJPEG()
            #expect(LocatedShareTestImage.locationProperties(of: original) != nil)
            let result = await MobileMediaExporter.exportOriginals(
                [item("located")], backend: ImageShareTestBackend(bytes: original))
            defer { MobileMediaExporter.cleanup(result.urls) }
            #expect(result.failed == 0)
            let shared = try Data(contentsOf: try #require(result.urls.first))
            if storedValue == false {
                #expect(shared == original)
            } else {
                // An unset preference removes the location and keeps the other metadata.
                #expect(LocatedShareTestImage.locationProperties(of: shared) == nil)
                #expect(LocatedShareTestImage.lensModel(of: shared) == LocatedShareTestImage.lensModel)
            }
        }
    }

    /// The viewer shares the shown original of an edited photo through the same export as every photo, so the location
    /// rule applies to the original too.
    @Test(arguments: [nil, false] as [Bool?])
    func shareOfAShownOriginalFollowsTheLocationPreference(storedValue: Bool?) async throws {
        try await SharingLocationPreferenceLease.with(storedValue: storedValue) {
            let edited = item("edited")
            let original = item("original")
            var state = EditedPhotoOriginalState()
            state.record(original, of: edited.uid)
            state.toggle(edited.uid)
            let bytes = try LocatedShareTestImage.makeLocatedJPEG()

            // Only the original has bytes, so a share of the edited version fails.
            let result = await MobileMediaExporter.exportOriginals(
                [state.displayed(edited)], backend: ImageShareTestBackend(bytes: bytes, onlyFor: original.uid))
            defer { MobileMediaExporter.cleanup(result.urls) }
            #expect(result.failed == 0)
            let shared = try Data(contentsOf: try #require(result.urls.first))
            if storedValue == false {
                #expect(shared == bytes)
            } else {
                #expect(LocatedShareTestImage.locationProperties(of: shared) == nil)
                #expect(LocatedShareTestImage.lensModel(of: shared) == LocatedShareTestImage.lensModel)
            }
        }
    }

    @Test func diskFullDuringADownloadStopsTheShare() async throws {
        let backend = ShareExportTestBackend()
        let result = await MobileMediaExporter.exportOriginals(
            [item("full")], backend: backend, availableCapacity: { _ in 1 << 40 })
        #expect(result.urls.isEmpty)
        #expect(result.failed == 1)
        #expect(result.ranOutOfSpace)

        let ordinary = await MobileMediaExporter.exportOriginals(
            [item("fail")], backend: backend, availableCapacity: { _ in 1 << 40 })
        #expect(!ordinary.ranOutOfSpace)
    }

    @Test func allFailedOrCancelledShareRemovesOnlyItsOwnDirectory() async throws {
        let support = try #require(await MobileMediaExporter.exportSupportReport(Data("keep".utf8)))
        defer { MobileMediaExporter.cleanup([support]) }
        let backend = ShareExportTestBackend()
        let failed = await MobileMediaExporter.exportOriginals([item("fail")], backend: backend)
        #expect(failed.urls.isEmpty)
        #expect(failed.failed == 1)
        let failedDirectory = try #require(await backend.directory(for: "fail"))
        #expect(!FileManager.default.fileExists(atPath: failedDirectory.path))
        let cancelled = Task { await MobileMediaExporter.exportOriginals([item("blocked")], backend: backend) }
        await backend.waitUntilBlocked()
        cancelled.cancel()
        await backend.release()
        let cancelledResult = await cancelled.value
        #expect(cancelledResult.urls.isEmpty)
        let cancelledDirectory = try #require(await backend.directory(for: "blocked"))
        #expect(!FileManager.default.fileExists(atPath: cancelledDirectory.path))
        #expect(FileManager.default.fileExists(atPath: support.path))
    }
}

private actor ShareExportTestBackend: OriginalFileProvider, PhotoMetadataProvider {
    private var directories: [String: URL] = [:]
    private var entered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        directories[uid.nodeID] = destination.deletingLastPathComponent()
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: destination)
        if uid.nodeID == "fail" { throw CocoaError(.fileWriteUnknown) }
        if uid.nodeID == "full" { throw CocoaError(.fileWriteOutOfSpace) }
        if uid.nodeID == "blocked" {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            if !isReleased {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        try Task.checkCancellation()
        onProgress(1)
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        PhotoMetadata(filename: "same.jpg", mimeType: "image/jpeg")
    }

    func directory(for id: String) -> URL? { directories[id] }

    func waitUntilBlocked() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct ImageShareTestBackend: OriginalFileProvider, PhotoMetadataProvider {
    let bytes: Data
    /// When set, only this photo has bytes; every other photo fails to download.
    var onlyFor: PhotoUID?

    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let onlyFor, uid != onlyFor { throw CocoaError(.fileReadNoSuchFile) }
        try bytes.write(to: destination)
        onProgress(1)
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        PhotoMetadata(filename: "located.jpg", mimeType: "image/jpeg")
    }
}
