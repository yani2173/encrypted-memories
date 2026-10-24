import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import Testing
import UniformTypeIdentifiers

@Suite(.serialized) struct TemporaryOriginalExporterTests {
    private func item(_ id: String) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "export-tests", nodeID: id),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000), mediaType: "image/jpeg")
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TemporaryExportTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func duplicateNamesKeepEveryOriginal() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = TemporaryOriginalExporter(exportRoot: root)
        let backend = TemporaryExportBackend()
        let result = await exporter.exportOriginals(
            [item("a"), item("b"), item("c")], backend: backend, removeLocationWhenSharing: { false })
        #expect(result.failed == 0)
        #expect(Set(result.urls.map(\.lastPathComponent)) == ["same.jpg", "same 2.jpg", "same 3.jpg"])
        #expect(Set(try result.urls.map { try Data(contentsOf: $0) }) == Set(["a", "b", "c"].map { Data($0.utf8) }))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: result.urls[0].deletingLastPathComponent().path).count
                == 3)
        exporter.cleanup(result.urls)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func itemFailuresLeavePartialResultsAndNoDownloadFiles() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = TemporaryOriginalExporter(exportRoot: root)
        let result = await exporter.exportOriginals(
            [item("a"), item("fail"), item("b")], backend: TemporaryExportBackend(),
            removeLocationWhenSharing: { false })
        #expect(result.urls.count == 2)
        #expect(result.failed == 1)
        #expect(!result.ranOutOfSpace)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: result.urls[0].deletingLastPathComponent().path).count
                == 2)
    }

    @Test func metadataFailureUsesTheExistingTimestampAndNodeFallback() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = item("missing-meta")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let result = await TemporaryOriginalExporter(exportRoot: root).exportOriginals(
            [photo], backend: TemporaryExportBackend(metadataFails: true), removeLocationWhenSharing: { false })
        #expect(result.failed == 0)
        #expect(
            result.urls.first?.lastPathComponent
                == "Encrypted-Memories-\(formatter.string(from: photo.captureTime))-g-meta.jpg")
    }

    @Test func lowCapacityStopsFurtherAdmission() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = TemporaryOriginalExporter(exportRoot: root)
        let backend = TemporaryExportBackend()
        let full = await exporter.exportOriginals(
            [item("a"), item("b")], backend: backend, availableCapacity: { _ in 0 },
            removeLocationWhenSharing: { false })
        #expect(full.urls.isEmpty)
        #expect(full.failed == 2)
        #expect(full.ranOutOfSpace)
        #expect(await backend.writes.isEmpty)
        var free: Int64 = 128 * 1024 * 1024
        let partial = await exporter.exportOriginals(
            [item("c"), item("d"), item("e")], backend: backend,
            availableCapacity: { _ in
                defer { free = 0 }
                return free
            }, removeLocationWhenSharing: { false })
        #expect(partial.urls.count == 1)
        #expect(partial.failed == 2)
        #expect(partial.ranOutOfSpace)
        #expect(await backend.writes.count == 1)
    }

    @Test func unknownCapacityStillAllowsExport() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await TemporaryOriginalExporter(exportRoot: root).exportOriginals(
            [item("a")], backend: TemporaryExportBackend(), availableCapacity: { _ in nil },
            removeLocationWhenSharing: { false })
        #expect(result.urls.count == 1)
        #expect(!result.ranOutOfSpace)
    }

    @Test func diskFullDuringAWriteStopsFurtherAdmission() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = TemporaryExportBackend()
        // Both admitted items fail with full disk, so either completion order stops further admission.
        let result = await TemporaryOriginalExporter(exportRoot: root).exportOriginals(
            [item("full-a"), item("full-b"), item("later")], backend: backend,
            availableCapacity: { _ in 1 << 40 }, removeLocationWhenSharing: { false })
        #expect(result.ranOutOfSpace)
        #expect(result.urls.isEmpty)
        #expect(result.failed == 3)
        #expect(await backend.writes.count == 2)
        #expect(await !backend.writes.keys.contains("later"))
    }

    @Test func concurrentJobsKeepSeparateDirectoriesAndTransferDemand() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = TemporaryOriginalExporter(exportRoot: root)
        let backend = TemporaryExportBackend(blocked: ["blocked"])
        let runtime = LibraryRuntimeState()
        let first = Task {
            await exporter.exportOriginals(
                [item("blocked")], backend: backend, runtimeState: runtime, removeLocationWhenSharing: { false })
        }
        #expect(await backend.waitForWrites(1))
        #expect(runtime.snapshot().activeUserTransferCount == 1)
        let second = await exporter.exportOriginals(
            [item("second")], backend: backend, removeLocationWhenSharing: { false })
        exporter.cleanup(second.urls)
        await backend.release()
        let result = await first.value
        #expect(result.urls.count == 1)
        #expect(result.urls.first?.deletingLastPathComponent() != second.urls.first?.deletingLastPathComponent())
        #expect(result.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(runtime.snapshot().activeUserTransferCount == 0)
    }

    @Test func cancellationRemovesCompletedAndInFlightOutput() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = TemporaryExportBackend(blocked: ["blocked"])
        let exporter = TemporaryOriginalExporter(exportRoot: root)
        let task = Task {
            await exporter.exportOriginals(
                [item("a"), item("blocked"), item("c")], backend: backend, removeLocationWhenSharing: { false })
        }
        #expect(await backend.waitForWrites(3))
        task.cancel()
        await backend.release()
        let result = await task.value
        #expect(result.urls.isEmpty)
        #expect(result.failed == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func emptyAndAlreadyCancelledInputsDoNoWork() async throws {
        let root = try root().appendingPathComponent("unused")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let exporter = TemporaryOriginalExporter(exportRoot: root)
        let backend = TemporaryExportBackend()
        let runtime = LibraryRuntimeState()
        let empty = await exporter.exportOriginals(
            [], backend: backend, runtimeState: runtime,
            availableCapacity: { _ in
                Issue.record("empty input queried capacity")
                return 0
            },
            removeLocationWhenSharing: {
                Issue.record("empty input queried privacy")
                return true
            })
        #expect(empty.urls.isEmpty && empty.failed == 0 && !empty.ranOutOfSpace)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await exporter.exportOriginals([item("a")], backend: backend, runtimeState: runtime)
        }
        let cancelled = await task.value
        #expect(cancelled.urls.isEmpty && cancelled.failed == 1)
        #expect(await backend.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(runtime.snapshot().activeUserTransferCount == 0)
    }

    @Test func cleanupAcceptsOnlyOwnedPathsAndPreservesOtherJobs() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = TemporaryOriginalExporter(exportRoot: root)
        let owned = root.appendingPathComponent(UUID().uuidString)
        let other = root.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("outside")
        for path in [owned, other, outside] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: path.appendingPathComponent("file"))
        }
        let link = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let legacy = root.appendingPathComponent("legacy")
        try Data("legacy".utf8).write(to: legacy)
        exporter.cleanup([
            owned.appendingPathComponent("file"), outside.appendingPathComponent("file"),
            link.appendingPathComponent("file"), legacy,
        ])
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file").path))
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("file").path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func unsafeMetadataNamesStayInsideTheJob() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await TemporaryOriginalExporter(exportRoot: root).exportOriginals(
            [item("a")], backend: TemporaryExportBackend(filename: "../escaped.jpg"),
            removeLocationWhenSharing: { false })
        #expect(result.urls.count == 1)
        #expect(result.urls.first?.lastPathComponent == "escaped.jpg")
        #expect(result.urls.first?.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent() == root)
    }

    @Test(arguments: [true, false]) func sanitizingFollowsTheJobPreference(removesLocation: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.jpg")
        let context = try #require(
            CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 12.25, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 45.5, kCGImagePropertyGPSLongitudeRef: "E",
                ],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Export test lens"],
            ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: original)
        var reads = 0
        let result = await TemporaryOriginalExporter(exportRoot: root).exportOriginals(
            [item("a"), item("b")], backend: TemporaryExportBackend(payload: bytes),
            removeLocationWhenSharing: {
                reads += 1
                return removesLocation
            })
        #expect(reads == 1)
        #expect(result.failed == 0)
        for url in result.urls {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect((properties[kCGImagePropertyGPSDictionary] == nil) == removesLocation)
            #expect(
                (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel]
                    as? String == "Export test lens")
            if !removesLocation { #expect(try Data(contentsOf: url) == bytes) }
        }
        #expect(try Data(contentsOf: original) == bytes)
    }
}

private actor TemporaryExportBackend: OriginalFileProvider, PhotoMetadataProvider {
    let filename: String
    let metadataFails: Bool
    let payload: Data?
    let blocked: Set<String>
    var writes: [String: URL] = [:]
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(filename: String = "same.jpg", metadataFails: Bool = false, payload: Data? = nil, blocked: Set<String> = []) {
        self.filename = filename
        self.metadataFails = metadataFails
        self.payload = payload
        self.blocked = blocked
    }

    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        writes[uid.nodeID] = destination
        try (payload ?? Data(uid.nodeID.utf8)).write(to: destination)
        if uid.nodeID == "fail" { throw CocoaError(.fileWriteUnknown) }
        if uid.nodeID.hasPrefix("full-") { throw CocoaError(.fileWriteOutOfSpace) }
        if blocked.contains(uid.nodeID), !released { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        onProgress(1)
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        if metadataFails { throw CocoaError(.fileReadUnknown) }
        return PhotoMetadata(filename: filename, mimeType: "image/jpeg")
    }

    func waitForWrites(_ count: Int) async -> Bool {
        for _ in 0..<400 {
            if writes.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
