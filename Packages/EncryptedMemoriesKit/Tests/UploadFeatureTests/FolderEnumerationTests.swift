import Photos
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

        monitor.startObserving {}
        let ranOnMain = await probe.wait()
        monitor.stopObserving()

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
