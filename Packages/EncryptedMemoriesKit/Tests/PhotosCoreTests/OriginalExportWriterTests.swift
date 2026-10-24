import Foundation
import Testing

@testable import PhotosCore

/// Behavior of the shared original export: staged destination writes, archive naming, failure cleanup, and
/// the low-disk guard. The Mac export uses these writes; iOS and iPadOS share the naming.
@Suite(.serialized) struct OriginalExportWriterTests {
    private static let heicHeader = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 52)
    private static let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 60)

    private func item(_ node: String, mediaType: String = "image/jpeg") -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: node),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000),
            mediaType: mediaType
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalExportWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func archiveEntries(_ archive: URL) throws -> [String] {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", archive.path]
        let output = Pipe()
        unzip.standardOutput = output
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// These byte-preservation fixtures opt out of sanitizing their synthetic, undecodable media headers.
    private func keepLocationForThisTest() -> () -> Void {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppSettingsKey.removeLocationWhenSharing)
        defaults.set(false, forKey: AppSettingsKey.removeLocationWhenSharing)
        return {
            if let original {
                defaults.set(original, forKey: AppSettingsKey.removeLocationWhenSharing)
            } else {
                defaults.removeObject(forKey: AppSettingsKey.removeLocationWhenSharing)
            }
        }
    }

    // MARK: - Naming

    @Test func decryptedFilenameWinsOverTheHeader() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("download")
        try Self.jpegHeader.write(to: file)

        let name = try OriginalExportWriter.exportFilename(
            forDownloadedOriginal: file,
            item: item("a"),
            metadata: PhotoMetadata(filename: "IMG_0001.HEIC"),
            fallbackBase: "fallback"
        )

        #expect(name == "IMG_0001.HEIC")
    }

    @Test func headerSuppliesTheExtensionWhenMetadataIsMissing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("download")
        try Self.heicHeader.write(to: file)

        let name = try OriginalExportWriter.exportFilename(
            forDownloadedOriginal: file,
            item: item("a"),
            metadata: nil,
            fallbackBase: "fallback"
        )

        #expect(name == "fallback.heic")
    }

    @Test func archiveNamesNeverCollide() {
        var used = Set<String>()
        #expect(OriginalExportWriter.uniqueArchiveName("IMG.HEIC", used: &used) == "IMG.HEIC")
        #expect(OriginalExportWriter.uniqueArchiveName("IMG.HEIC", used: &used) == "IMG 2.HEIC")
        #expect(OriginalExportWriter.uniqueArchiveName("IMG.HEIC", used: &used) == "IMG 3.HEIC")
        #expect(OriginalExportWriter.uniqueArchiveName("README", used: &used) == "README")
        #expect(OriginalExportWriter.uniqueArchiveName("README", used: &used) == "README 2")
    }

    // MARK: - Destination writes

    @Test func singleExportInstallsTheCompleteOriginalAndReplacesAnExistingFile() async throws {
        let restorePreference = keepLocationForThisTest()
        defer { restorePreference() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("IMG_0001.HEIC")
        try Data("old".utf8).write(to: destination)
        let photo = item("a")
        let provider = FakeOriginalProvider(payloads: [photo.uid: Self.heicHeader])

        try await OriginalExportWriter.writeSingle(item: photo, to: destination, provider: provider) { _ in }

        #expect(try Data(contentsOf: destination) == Self.heicHeader)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["IMG_0001.HEIC"])
    }

    @Test func failedSingleExportLeavesTheDestinationUntouched() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("IMG_0001.HEIC")
        let photo = item("a")
        let provider = FakeOriginalProvider(payloads: [:], failing: [photo.uid])

        await #expect(throws: FakeOriginalProvider.Failure.self) {
            try await OriginalExportWriter.writeSingle(item: photo, to: destination, provider: provider) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func archiveExportNamesEveryEntryUniquelyAndReportsCompletion() async throws {
        let restorePreference = keepLocationForThisTest()
        defer { restorePreference() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Export.zip")
        let first = item("aaaaaaaa-first")
        let second = item("bbbbbbbb-second")
        let third = item("cccccccc-third")
        let provider = FakeOriginalProvider(
            payloads: [first.uid: Self.heicHeader, second.uid: Self.heicHeader, third.uid: Self.jpegHeader],
            metadata: [
                first.uid: PhotoMetadata(filename: "IMG_0001.HEIC"),
                second.uid: PhotoMetadata(filename: "IMG_0001.HEIC"),
            ]
        )
        let progress = RecordLog<Double>()

        try await OriginalExportWriter.writeArchive(
            items: [first, second, third], to: destination, provider: provider
        ) { progress.record($0) }

        #expect(try archiveEntries(destination) == ["IMG_0001.HEIC", "IMG_0001 2.HEIC", "cccccccc.jpg"])
        #expect(progress.values.last == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Export.zip"])
    }

    @Test func writeDataWritesTheBytesAndReplacesAnExistingFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Support.json")

        try OriginalExportWriter.writeData(Data("first".utf8), to: destination)
        #expect(try Data(contentsOf: destination) == Data("first".utf8))

        try OriginalExportWriter.writeData(Data("second".utf8), to: destination)
        #expect(try Data(contentsOf: destination) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Support.json"])
    }

    @Test func writeDataLeavesNoStagingDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Support.json")
        let staging = RecordLog<URL>()
        defer {
            for url in staging.values { try? FileManager.default.removeItem(at: url) }
        }

        try OriginalExportWriter.$stagingDirectoryObserver.withValue(
            { staging.record($0) },
            operation: { try OriginalExportWriter.writeData(Data("report".utf8), to: destination) })

        #expect(try Data(contentsOf: destination) == Data("report".utf8))
        try #require(staging.values.count == 1, "writeData stages through exactly one directory")
        #expect(!FileManager.default.fileExists(atPath: staging.values[0].path))
    }

    @Test func failedArchiveExportRemovesThePartialArchive() async throws {
        let restorePreference = keepLocationForThisTest()
        defer { restorePreference() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Export.zip")
        let first = item("first")
        let second = item("second")
        let provider = FakeOriginalProvider(payloads: [first.uid: Self.jpegHeader], failing: [second.uid])

        await #expect(throws: FakeOriginalProvider.Failure.self) {
            try await OriginalExportWriter.writeArchive(
                items: [first, second], to: destination, provider: provider
            ) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func archiveExportStopsBeforeTheVolumeRunsOutOfSpace() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Export.zip")
        let photo = item("first")
        let provider = FakeOriginalProvider(
            payloads: [photo.uid: Self.jpegHeader],
            metadata: [photo.uid: PhotoMetadata(filename: "IMG.JPG", fileSize: 1_000)]
        )

        await #expect(throws: OriginalExportWriter.Failure.lowDisk) {
            try await OriginalExportWriter.writeArchive(
                items: [photo], to: destination, provider: provider, freeBytes: { _ in 1_024 },
                onProgress: { _ in })
        }

        #expect(provider.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

private final class FakeOriginalProvider: OriginalFileProvider, PhotoMetadataProvider, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private let payloads: [PhotoUID: Data]
    private let metadataByUID: [PhotoUID: PhotoMetadata]
    private let failing: Set<PhotoUID>
    private var writes = 0

    init(
        payloads: [PhotoUID: Data],
        metadata: [PhotoUID: PhotoMetadata] = [:],
        failing: Set<PhotoUID> = []
    ) {
        self.payloads = payloads
        self.metadataByUID = metadata
        self.failing = failing
    }

    var writeCount: Int { lock.withLock { writes } }

    func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        lock.withLock { writes += 1 }
        guard !failing.contains(uid), let payload = payloads[uid] else { throw Failure() }
        try payload.write(to: destination)
        onProgress(1)
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        guard let metadata = metadataByUID[uid] else { throw Failure() }
        return metadata
    }
}

private final class RecordLog<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Value] = []

    func record(_ value: Value) { lock.withLock { recorded.append(value) } }
    var values: [Value] { lock.withLock { recorded } }
}
