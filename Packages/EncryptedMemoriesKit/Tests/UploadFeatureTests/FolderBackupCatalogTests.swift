import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class FolderBackupCatalogTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-backup-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func collect(_ catalog: FolderBackupCatalog) async throws -> [UploadBackupAssetCandidate] {
        var out: [UploadBackupAssetCandidate] = []
        for try await candidate in catalog.candidates() { out.append(candidate) }
        return out
    }

    func testStreamsSupportedMediaInDeterministicOrderWithOriginalNames() async throws {
        let sub = tempDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: tempDir.appendingPathComponent("b.jpg"))
        try Data("aaaa".utf8).write(to: tempDir.appendingPathComponent("A.PNG"))
        try Data("v".utf8).write(to: sub.appendingPathComponent("clip.mov"))
        try Data("no".utf8).write(to: tempDir.appendingPathComponent("notes.txt"))
        try Data("h".utf8).write(to: tempDir.appendingPathComponent(".hidden.jpg"))

        let candidates = try await collect(FolderBackupCatalog(folder: tempDir))

        XCTAssertEqual(
            candidates.map(\.originalFilename), ["A.PNG", "b.jpg", "clip.mov"],
            "order must be the enumerator's deterministic path sort; unsupported and hidden files are excluded")
        XCTAssertEqual(candidates.map(\.byteCount), [4, 1, 1])
        for candidate in candidates {
            XCTAssertEqual(candidate.snapshot.source.kind, .fileURL)
            XCTAssertEqual(candidate.snapshot.source.resource, .primary)
            XCTAssertEqual(candidate.snapshot.resourceCount, 1)
            XCTAssertEqual(
                candidate.snapshot.editRevision, .unavailable,
                "mutable file sources must never claim trusted edit evidence")
        }
    }

    func testRevisionTracksModificationTime() async throws {
        let file = tempDir.appendingPathComponent("shot.heic")
        try Data("x".utf8).write(to: file)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let candidates = try await collect(FolderBackupCatalog(folder: tempDir))

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].snapshot.revision, UploadBackupRevision(date: modified))
    }

    func testEmptyFolderYieldsNothingAndMissingFolderThrows() async throws {
        let empty = try await collect(FolderBackupCatalog(folder: tempDir))
        XCTAssertTrue(empty.isEmpty)

        let missingURL = tempDir.appendingPathComponent("nope")
        do {
            _ = try await collect(FolderBackupCatalog(folder: missingURL))
            XCTFail("a missing folder must not look like an empty successful scan")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.operation, .readDirectory)
            XCTAssertEqual(error.failureClass, .missing)
            XCTAssertEqual(error.url, missingURL)
        }
    }

    func testDoesNotReadAheadPastTheRequestedCandidate() async throws {
        let later = tempDir.appendingPathComponent("z-later", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: tempDir.appendingPathComponent("a-first.jpg"))
        try Data("later".utf8).write(to: later.appendingPathComponent("later.jpg"))

        var iterator = FolderBackupCatalog(folder: tempDir).candidates().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.originalFilename, "a-first.jpg")

        try FileManager.default.removeItem(at: later)
        do {
            _ = try await iterator.next()
            XCTFail("the next directory must be read only when the consumer requests another candidate")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.operation, .readDirectory)
            XCTAssertEqual(error.failureClass, .missing)
            XCTAssertEqual(error.url.lastPathComponent, "z-later")
        }
    }

    private static let skipCounterKeys = [
        "folderScan.unreadableEntrySkips.missing",
        "folderScan.unreadableEntrySkips.permissionDenied",
        "folderScan.unreadableEntrySkips.transient",
    ]

    private func skipCounters() -> [Int] {
        Self.skipCounterKeys.map { PhotoDiagnostics.shared.counter($0) }
    }

    private func writeFiles(_ names: [String]) throws {
        for name in names {
            try Data("x".utf8).write(to: tempDir.appendingPathComponent(name))
        }
    }

    private func restoreAccess() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
    }

    func testCandidatesSkipAnEntryWhoseAttributesCannotBeReadAndContinue() async throws {
        try writeFiles(["a.jpg", "b.jpg", "z.jpg"])
        // The listing reads every resource value, so only the attribute read of b.jpg fails.
        let failedReads = ReadCounter()
        let catalog = FolderBackupCatalog(folder: tempDir, includeHidden: false) { path in
            guard (path as NSString).lastPathComponent == "b.jpg" else {
                return try FileManager.default.attributesOfItem(atPath: path)
            }
            failedReads.increment()
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }

        let skippedPermission = PhotoDiagnostics.shared.counter("folderScan.unreadableEntrySkips.permissionDenied")
        let candidates = try await collect(catalog)

        XCTAssertEqual(failedReads.value, 1, "the skip must happen at the attribute read")
        XCTAssertEqual(
            candidates.map(\.originalFilename), ["a.jpg", "z.jpg"],
            "one unreadable entry must be skipped and never end the scan")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("folderScan.unreadableEntrySkips.permissionDenied"),
            skippedPermission + 1,
            "a skip must leave a class-only hint on the internal diagnostics surface, without names or paths")
        let exported = PhotoDiagnostics.shared.supportSnapshot()
            .counters["folderScan.unreadableEntrySkips.permissionDenied"]
        XCTAssertEqual(
            exported, skippedPermission + 1,
            "the skip hint must be part of the existing support diagnostics export")
    }

    func testFolderThatCannotBeSearchedFailsInsteadOfAnEmptyScan() async throws {
        try writeFiles(["a.jpg", "b.jpg"])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tempDir.path)
        defer { restoreAccess() }

        let before = skipCounters()
        do {
            _ = try await collect(FolderBackupCatalog(folder: tempDir))
            XCTFail("a folder without search permission must not look like an empty successful scan")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.operation, .readDirectory)
            XCTAssertEqual(error.failureClass, .permissionDenied)
            XCTAssertTrue(error.requiresRootAccessRenewal(for: tempDir))
        }
        XCTAssertEqual(skipCounters(), before, "a folder failure must not count as skipped entries")
    }

    func testFolderThatLosesSearchPermissionDuringTheScanFailsInsteadOfSkippingEveryEntry() async throws {
        try writeFiles(["a.jpg", "b.jpg", "z.jpg"])
        defer { restoreAccess() }

        let before = skipCounters()
        var iterator = FolderBackupCatalog(folder: tempDir).candidates().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.originalFilename, "a.jpg")

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tempDir.path)
        do {
            while try await iterator.next() != nil {}
            XCTFail("a folder that lost access must not end as a successful scan")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.operation, .readDirectory)
            XCTAssertEqual(error.failureClass, .permissionDenied)
            XCTAssertEqual(error.url, tempDir)
            XCTAssertTrue(error.requiresRootAccessRenewal(for: tempDir))
        }
        XCTAssertEqual(skipCounters(), before, "a folder failure must not count as skipped entries")
    }

    #if os(macOS)
        func testCandidatesSkipAFileWhosePermissionsDenyReadingItsDetails() async throws {
            try writeFiles(["a.jpg", "b.jpg", "z.jpg"])
            let denied = tempDir.appendingPathComponent("b.jpg")
            try runChmod(["+a", "everyone deny readattr,readextattr,readsecurity", denied.path])
            defer { try? runChmod(["-N", denied.path]) }

            let skippedPermission = PhotoDiagnostics.shared.counter(
                "folderScan.unreadableEntrySkips.permissionDenied")
            let candidates = try await collect(FolderBackupCatalog(folder: tempDir))

            XCTAssertEqual(
                candidates.map(\.originalFilename), ["a.jpg", "z.jpg"],
                "a file whose own permissions deny reading its details must not stop the scan")
            XCTAssertEqual(
                PhotoDiagnostics.shared.counter("folderScan.unreadableEntrySkips.permissionDenied"),
                skippedPermission + 1)
        }

        private func runChmod(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "chmod \(arguments.first ?? "")")
        }
    #endif
}

/// Counts reads across the scan's detached tasks.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
