import Photos
import PhotosCore
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

final class FolderEnumerationTests: XCTestCase {
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("enum-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        func write(_ rel: String) throws { try Data("x".utf8).write(to: root.appendingPathComponent(rel)) }
        try write("photo1.jpg")
        try write(".hidden.jpg")  // hidden - skipped by default
        try write("note.txt")  // unsupported - reported, not uploaded
        try write("sub/photo2.png")  // nested media
        try write("sub/clip.mov")  // nested video
        try write("sub/.DS_Store")  // hidden junk
        return root
    }

    private func collect(_ folder: URL, includeHidden: Bool = false) async throws -> [FolderEnumerator.Entry] {
        var entries: [FolderEnumerator.Entry] = []
        for try await entry in FolderEnumerator.stream(folder, includeHidden: includeHidden) {
            entries.append(entry)
        }
        return entries
    }

    func testDiscoversMediaRecursivelyAndSkipsHiddenAndUnsupported() async throws {
        let root = try makeTree()
        let entries = try await collect(root)
        let names = Set(entries.filter(\.isSupported).map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["photo1.jpg", "photo2.png", "clip.mov"])
        XCTAssertFalse(names.contains(".hidden.jpg"))
        XCTAssertEqual(entries.filter { !$0.isSupported }.map { $0.url.lastPathComponent }, ["note.txt"])
    }

    func testDeterministicOrdering() async throws {
        let root = try makeTree()
        let a = try await collect(root).filter(\.isSupported).map { $0.url.path }
        let b = try await collect(root).filter(\.isSupported).map { $0.url.path }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, a.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testStreamDoesNotPreEnumerateLaterDirectories() async throws {
        let root = try makeTree()
        let lateDirectory = root.appendingPathComponent("z")
        try FileManager.default.createDirectory(at: lateDirectory, withIntermediateDirectories: true)

        var visited: [String] = []
        for try await entry in FolderEnumerator.stream(root) {
            guard entry.isSupported else { continue }
            visited.append(entry.url.lastPathComponent)
            if entry.url.lastPathComponent == "photo1.jpg" {
                try Data("late".utf8).write(to: lateDirectory.appendingPathComponent("late.jpg"))
            }
        }

        XCTAssertEqual(visited, ["photo1.jpg", "clip.mov", "photo2.png", "late.jpg"])
    }

    func testDoesNotTraverseSymbolicLinkDirectories() async throws {
        let root = try makeTree()
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("linked".utf8).write(to: target.appendingPathComponent("linked.jpg"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"),
            withDestinationURL: target
        )

        let media = try await collect(root).filter(\.isSupported).map { $0.url.lastPathComponent }

        XCTAssertEqual(media.filter { $0 == "linked.jpg" }.count, 1)
    }

    func testIncludeHiddenOptIn() async throws {
        let root = try makeTree()
        let entries = try await collect(root, includeHidden: true)
        let names = Set(entries.filter(\.isSupported).map { $0.url.lastPathComponent })
        XCTAssertTrue(names.contains(".hidden.jpg"))
    }

    func testAsyncStreamPreservesDeterministicSupportedMediaOrder() async throws {
        let root = try makeTree()
        let iterator = FolderEnumerator.stream(root).makeAsyncIterator()
        var names: [String] = []

        while let entry = try await iterator.next() {
            if entry.isSupported {
                names.append(entry.url.lastPathComponent)
            }
        }

        XCTAssertEqual(names, ["photo1.jpg", "clip.mov", "photo2.png"])
    }

    func testAsyncStreamDoesNotRetainLaterSubtreeBeforeFirstItem() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("enum-stream-\(UUID().uuidString)", isDirectory: true)
        let later = root.appendingPathComponent("z-later", isDirectory: true)
        try fileManager.createDirectory(at: later, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: root.appendingPathComponent("a-first.jpg"))
        for index in 0..<512 {
            try Data("later".utf8).write(to: later.appendingPathComponent("photo-\(index).jpg"))
        }

        let iterator = FolderEnumerator.stream(root).makeAsyncIterator()
        guard let first = try await iterator.next() else {
            XCTFail("the stream must yield the first file")
            return
        }
        XCTAssertEqual(first.url.lastPathComponent, "a-first.jpg")

        try fileManager.removeItem(at: later)
        do {
            while let entry = try await iterator.next() {
                if entry.isSupported {
                    XCTFail("the removed subtree must not yield a queued file: \(entry.url.path)")
                }
            }
            XCTFail("the removed subtree must surface its directory-read failure")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.operation, .readDirectory)
            XCTAssertEqual(error.failureClass, .missing)
            XCTAssertEqual(error.url.lastPathComponent, later.lastPathComponent)
            XCTAssertEqual(
                error.url.deletingLastPathComponent().resolvingSymlinksInPath(),
                later.deletingLastPathComponent().resolvingSymlinksInPath()
            )
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

    private func makeFlatFolder(_ fileManager: FileManager, names: [String]) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("enum-skip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    func testAsyncStreamSkipsAnUnreadableEntryAndContinuesWithLaterEntries() async throws {
        let fileManager = NoPrefetchListingFileManager()
        let root = try makeFlatFolder(fileManager, names: ["a.jpg", "b.jpg", "z.jpg"])
        defer { try? fileManager.removeItem(at: root) }

        let skippedMissing = PhotoDiagnostics.shared.counter("folderScan.unreadableEntrySkips.missing")
        let iterator = FolderEnumerator.stream(root, fileManager: fileManager).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.url.lastPathComponent, "a.jpg")

        // The entry vanishes after its directory was listed, so the scan cannot read its
        // resource values: exactly one unreadable entry between two readable ones.
        try fileManager.removeItem(at: root.appendingPathComponent("b.jpg"))

        var later: [String] = []
        while let entry = try await iterator.next() {
            later.append(entry.url.lastPathComponent)
        }

        XCTAssertEqual(later, ["z.jpg"], "one unreadable entry must be skipped and never end the scan")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("folderScan.unreadableEntrySkips.missing"),
            skippedMissing + 1,
            "a skip must leave a class-only hint on the internal diagnostics surface, without names or paths")
        let exported = PhotoDiagnostics.shared.supportSnapshot()
            .counters["folderScan.unreadableEntrySkips.missing"]
        XCTAssertEqual(
            exported, skippedMissing + 1,
            "the skip hint must be part of the existing support diagnostics export")
    }

    func testAsyncStreamFailsTheFolderWhenItLosesSearchPermissionDuringTheScan() async throws {
        let fileManager = NoPrefetchListingFileManager()
        let root = try makeFlatFolder(fileManager, names: ["a.jpg", "b.jpg", "z.jpg"])
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fileManager.removeItem(at: root)
        }

        let before = skipCounters()
        let iterator = FolderEnumerator.stream(root, fileManager: fileManager).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.url.lastPathComponent, "a.jpg")

        // Reading an entry needs search permission on its folder. Without it every later entry
        // fails, which is a failure of the folder, not of one entry.
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.path)
        do {
            while try await iterator.next() != nil {}
            XCTFail("a folder that lost access must not end as a successful scan")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.operation, .readDirectory)
            XCTAssertEqual(error.failureClass, .permissionDenied)
            XCTAssertEqual(error.url, root)
            XCTAssertTrue(error.requiresRootAccessRenewal(for: root))
        }
        XCTAssertEqual(skipCounters(), before, "a folder failure must not count as skipped entries")
    }

    func testAsyncStreamFailsTheFolderWhenItIsReplacedDuringTheScan() async throws {
        let fileManager = NoPrefetchListingFileManager()
        let root = try makeFlatFolder(fileManager, names: [])
        defer { try? fileManager.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "z.jpg"] {
            try Data("x".utf8).write(to: sub.appendingPathComponent(name))
        }

        let before = skipCounters()
        let iterator = FolderEnumerator.stream(root, fileManager: fileManager).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.url.lastPathComponent, "a.jpg")

        // An unmounted volume can leave its mount point behind as an empty directory: the path
        // still exists and is searchable, but it is no longer the listed directory.
        try fileManager.moveItem(at: sub, to: root.appendingPathComponent("sub-moved", isDirectory: true))
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        do {
            while try await iterator.next() != nil {}
            XCTFail("a replaced folder must not end as a successful scan")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.operation, .readDirectory)
            XCTAssertEqual(error.failureClass, .missing)
            XCTAssertEqual(error.url, sub)
        }
        XCTAssertEqual(skipCounters(), before, "a folder failure must not count as skipped entries")
    }

    func testTypedFilesystemErrorPreservesClassificationAndLocation() {
        let url = URL(fileURLWithPath: "/private/tmp/denied")
        let permission = FolderEnumerationError(
            operation: .readDirectory,
            url: url,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))
        )
        XCTAssertEqual(permission.failureClass, .permissionDenied)
        XCTAssertEqual(permission.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(permission.code, Int(POSIXErrorCode.EACCES.rawValue))
        XCTAssertEqual(permission.path, url.path)
        XCTAssertTrue(permission.localizedDescription.contains("permissionDenied"))

        let transient = FolderEnumerationError(
            operation: .resourceValues,
            url: url,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EIO.rawValue))
        )
        XCTAssertEqual(transient.failureClass, .transient)

        let wrapped = FolderEnumerationError(
            operation: .readDirectory,
            url: url,
            error: NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(POSIXErrorCode.EPERM.rawValue)
                    )
                ]
            )
        )
        XCTAssertEqual(wrapped.failureClass, .permissionDenied)

        XCTAssertTrue(permission.requiresRootAccessRenewal(for: url))
        XCTAssertFalse(permission.requiresRootAccessRenewal(for: url.deletingLastPathComponent()))
        XCTAssertFalse(transient.requiresRootAccessRenewal(for: url))
    }

    func testSkipUnreadableEntryRuleEligibility() throws {
        let folder = try makeFlatFolder(.default, names: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = try FolderEnumerator.ListedDirectory.read(folder)

        // Only entry metadata failures are eligible; each records its class on the internal
        // diagnostics surface.
        for (operation, failureClass) in [
            (FolderEnumerationError.Operation.resourceValues, FolderEnumerationError.FailureClass.permissionDenied),
            (FolderEnumerationError.Operation.attributes, FolderEnumerationError.FailureClass.transient),
        ] {
            let key = "folderScan.unreadableEntrySkips.\(failureClass.rawValue)"
            let before = PhotoDiagnostics.shared.counter(key)
            let error = FolderEnumerationError(
                operation: operation,
                url: folder.appendingPathComponent("x.jpg"),
                failureClass: failureClass,
                domain: "Test",
                code: 1
            )
            XCTAssertTrue(try FolderEnumerator.skipUnreadableEntry(error, in: parent), "\(operation) must be skippable")
            XCTAssertEqual(PhotoDiagnostics.shared.counter(key), before + 1, "\(operation) must record its class")
        }

        // Directory reads and non-enumeration errors still fail the scan and record nothing.
        let before = skipCounters()
        let readDirectoryError = FolderEnumerationError(
            operation: .readDirectory,
            url: folder,
            failureClass: .missing,
            domain: "Test",
            code: 1
        )
        XCTAssertFalse(try FolderEnumerator.skipUnreadableEntry(readDirectoryError, in: parent))
        XCTAssertFalse(try FolderEnumerator.skipUnreadableEntry(CancellationError(), in: parent))
        XCTAssertEqual(skipCounters(), before, "a refused error must not count as a skipped entry")
    }

    func testAsyncStreamChecksCancellationBetweenEntries() async throws {
        let root = try makeTree()
        let beforeSecond = EnumerationGate()
        let allowSecond = EnumerationGate()
        let task = Task { () throws -> FolderEnumerator.Entry? in
            let iterator = FolderEnumerator.stream(root).makeAsyncIterator()
            _ = try await iterator.next()
            await beforeSecond.signal()
            await allowSecond.wait()
            return try await iterator.next()
        }

        await beforeSecond.wait()
        task.cancel()
        await allowSecond.signal()

        do {
            _ = try await task.value
            XCTFail("a cancelled folder stream must stop before the next item")
        } catch is CancellationError {
            // Expected.
        }
    }
}

final class SupportedMediaTests: XCTestCase {
    func testImageAndVideoDetection() {
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.JPG")), "image/jpeg")
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.heic")), "image/heic")
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.DNG")), "image/x-adobe-dng")
        XCTAssertEqual(SupportedMedia.kind(for: URL(fileURLWithPath: "/x/a.mov")), .video)
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.mp4")), "video/mp4")
    }

    func testUnsupportedReturnsNil() {
        XCTAssertNil(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.txt")))
        XCTAssertFalse(SupportedMedia.isSupported(URL(fileURLWithPath: "/x/a.pdf")))
    }
}

final class PhotoLibraryChangeMonitorTests: XCTestCase {
    func testInitialFullLibraryFetchRunsOffTheMainThread() async {
        let probe = FetchThreadProbe()
        let monitor = PhotoLibraryChangeMonitor(
            tokenURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("photo-library-change-monitor-\(UUID().uuidString)"),
            fetchObservedAssets: {
                probe.record(Thread.isMainThread)
                return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
            }
        )

        let subscription = monitor.subscribe {}
        let ranOnMain = await probe.wait()
        subscription.cancel()

        XCTAssertFalse(ranOnMain)
    }
}

private final class FetchThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func record(_ ranOnMain: Bool) {
        let continuation = lock.withLock {
            result = ranOnMain
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(returning: ranOnMain)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate: Bool? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

private actor EnumerationGate {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

/// Lists directory children through fresh URLs, without the prefetch cache of
/// `contentsOfDirectory(at:includingPropertiesForKeys:options:)`. An entry removed after its
/// directory was listed then behaves like an entry whose metadata truly cannot be read.
private final class NoPrefetchListingFileManager: FileManager {
    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let names = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: options)
            .map(\.lastPathComponent)
        return names.map { url.appendingPathComponent($0) }
    }
}
