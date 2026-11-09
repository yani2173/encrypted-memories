import Foundation

/// Enumerates one entry at a time. Names and URLs remain inside this adapter.
final class ThumbnailSupportMetadataIterator: @unchecked Sendable {
    struct Stopped: Error {}
    enum ProbeStep {
        case rootRead, rootReadCompleted, enumeratorAttempt, enumeratorCreated, nextObjectAttempt, nextObject, entryRead
    }

    private final class ErrorState: @unchecked Sendable {
        private let lock = NSLock()
        private var error: (any Error)?
        func set(_ error: any Error) { lock.withLock { self.error = error } }
        func take() -> (any Error)? {
            lock.withLock {
                defer { error = nil }
                return error
            }
        }
    }

    private let errors: ErrorState
    private let enumerator: FileManager.DirectoryEnumerator?
    private let shouldStop: @Sendable () -> Bool
    private let probe: @Sendable (ProbeStep) -> Void
    #if DEBUG
        private let testingLock = NSLock()
        private var forceUnknownRegularFile = false

        func forceUnknownRegularFileForTesting() {
            testingLock.withLock { forceUnknownRegularFile = true }
        }
    #endif

    init(
        directory: URL, probe: @escaping @Sendable (ProbeStep) -> Void = { _ in },
        shouldStop: @escaping @Sendable () -> Bool
    ) {
        let errors = ErrorState()
        self.errors = errors
        self.shouldStop = shouldStop
        self.probe = probe
        guard !shouldStop() else {
            self.enumerator = nil
            return
        }
        probe(.rootRead)
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            self.enumerator = nil
            return
        }
        probe(.rootReadCompleted)
        guard !shouldStop() else {
            self.enumerator = nil
            return
        }
        probe(.enumeratorAttempt)
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                errors.set(error)
                return false
            })
        probe(.enumeratorCreated)
        guard !shouldStop() else {
            self.enumerator = nil
            return
        }
        self.enumerator = enumerator
    }

    var available: Bool { enumerator != nil }

    func next() throws -> Int64? {
        guard let enumerator else { return nil }
        while true {
            if shouldStop() { throw Stopped() }
            if let error = errors.take() { throw error }
            probe(.nextObjectAttempt)
            guard let entry = enumerator.nextObject() as? URL else {
                if let error = errors.take() { throw error }
                return nil
            }
            probe(.nextObject)
            if shouldStop() { throw Stopped() }
            guard entry.pathExtension == "blob" else { continue }
            probe(.entryRead)
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            #if DEBUG
                let regularFile = testingLock.withLock { forceUnknownRegularFile ? nil : values.isRegularFile }
            #else
                let regularFile = values.isRegularFile
            #endif
            guard let isRegularFile = regularFile else { throw CocoaError(.fileReadUnknown) }
            guard isRegularFile else { continue }
            guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
            return Int64(size)
        }
    }
}
