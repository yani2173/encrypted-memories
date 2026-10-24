import Foundation

// MARK: - Drag-out staging

/// Failure surfaced by ``DragOutStager``.
public enum DragOutStagingFailure: Error, Sendable, Equatable {
    case cancelled
    case diskSpaceInsufficient(required: Int64, available: Int64)
    case writeFailed(String)
}

/// Stages decrypted originals for an active drag session, platform-neutral (Foundation only).
///
/// Strategy A: `beginPreflight`+staging start immediately at drag begin, bounded by
/// `maxConcurrentWrites`. Completed items sit as stable plaintext files inside
/// `stagingDirectory` until delivery or cleanup. Plaintext lives only as transient files on
/// disk; `finishAndCleanup()` removes everything not marked delivered.
public actor DragOutStager {
    private let fileProvider: any OriginalFileProvider
    private let stagingDirectory: URL
    private let safetyMarginBytes: Int64
    private let maxConcurrentWrites: Int
    private let runtimeState: LibraryRuntimeState
    /// Read when a file is written, so a setting changed during a long drag applies to every later file.
    private let removeLocationWhenSharing: @Sendable () -> Bool

    private enum JobState {
        case pending
        case running(Task<Void, Never>)
        case staged(URL)
        case delivered(URL?)
        case failed(DragOutStagingFailure)
    }

    private var jobs: [PhotoUID: JobState] = [:]
    private var queue: [PhotoUID] = []
    private var runningCount = 0
    private var progressHandler: (@Sendable (PhotoUID, Double) -> Void)?
    /// Nonisolated progress fan-out; updated from the actor whenever the handler changes.
    private let progressRelay = ProgressRelay()
    private var deliveredUIDs: Set<PhotoUID> = []
    /// True once `beginPrefetch` entered this stager; distinguishes "registry not built yet"
    /// from "job already cleaned up" in `awaitStaged`.
    private var didBeginPrefetch = false
    /// True after `cancelAll`/`finishAndCleanup`; ends pre-prefetch parking in `awaitStaged`.
    private var isCancelled = false

    public init(
        fileProvider: any OriginalFileProvider,
        stagingDirectory: URL,
        safetyMarginBytes: Int64 = 128 * 1024 * 1024,
        maxConcurrentWrites: Int = 2,
        runtimeState: LibraryRuntimeState = .shared,
        removeLocationWhenSharing: @escaping @Sendable () -> Bool = { PrivacyExportPolicy.isEnabled() }
    ) {
        self.fileProvider = fileProvider
        self.stagingDirectory = stagingDirectory
        self.safetyMarginBytes = safetyMarginBytes
        self.maxConcurrentWrites = max(1, maxConcurrentWrites)
        self.runtimeState = runtimeState
        self.removeLocationWhenSharing = removeLocationWhenSharing
    }

    // MARK: - Public API

    /// Sums known item sizes, checks the staging volume, then starts staging every item
    /// immediately (FIFO, bounded by `maxConcurrentWrites`). Unknown size ⇒ `nil`
    /// `totalKnownBytes` and the preflight allows (progress UI handles sizing).
    @discardableResult
    public func beginPrefetch(items: [PhotoItem]) async -> DragOutPreflightDecision {
        precondition(!items.isEmpty, "DragOutStager.beginPrefetch needs at least one item")
        // Marks the session as started for `awaitStaged`'s pre-prefetch parking. The body
        // below contains no suspension points, so once this flag is observable the job
        // registry has already reached its final state for this call.
        didBeginPrefetch = true
        isCancelled = false
        var totalKnownBytes: Int64? = 0
        for item in items {
            if let size = size(for: item) {
                totalKnownBytes = (totalKnownBytes ?? 0) + Int64(size)
            } else {
                totalKnownBytes = nil
                break
            }
        }
        let free = DeviceStorage.availableCapacity(at: stagingDirectory) ?? 0
        let decision = DragOutPolicy.preflight(
            totalKnownBytes: totalKnownBytes,
            freeDiskBytes: free,
            safetyMarginBytes: safetyMarginBytes
        )
        if !decision.isAllowed, case .insufficientDiskSpace(let required, let available)? = decision.blockReason {
            for item in items where jobs[item.uid] == nil {
                jobs[item.uid] = .failed(.diskSpaceInsufficient(required: required, available: available))
            }
            return decision
        }

        // Directory must exist before the first .download file appears.
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        for item in items {
            guard jobs[item.uid] == nil else { continue }
            jobs[item.uid] = .pending
            queue.append(item.uid)
        }
        pumpQueue()
        return decision
    }

    /// Suspends until the item's file is fully staged. Success is a stable plaintext URL inside
    /// `stagingDirectory`.
    public func awaitStaged(uid: PhotoUID) async -> Result<URL, DragOutStagingFailure> {
        var parkedTooLong = 0
        while true {
            switch jobs[uid] {
            case .staged(let url), .delivered(let url?):
                if FileManager.default.fileExists(atPath: url.path) {
                    return .success(url)
                }
                // File vanished underneath us; cleanup took it.
                return .failure(.cancelled)
            case .delivered(nil):
                return .failure(.cancelled)
            case .failed(let failure):
                return .failure(failure)
            case nil:
                if !didBeginPrefetch, !isCancelled {
                    // The system's load handler can beat this stager's `beginPrefetch` task onto
                    // the actor; park briefly until the job registry exists. Bounded so a stager
                    // whose prefetch never arrives fails the drop instead of hanging it.
                    parkedTooLong += 1
                    if parkedTooLong <= 400 {  // ~2 s at 5 ms per pass
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        continue
                    }
                }
                // Job finished and was cleaned up (cancelAll/finishAndCleanup), or prefetch
                // never arrived in time.
                return .failure(.cancelled)
            case .pending, .running:
                // Park briefly; the job's completion mutates state in this actor.
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    /// Sets per-item progress, fraction 0…1. Passing `nil` clears the handler.
    public func setProgressHandler(_ handler: (@Sendable (PhotoUID, Double) -> Void)?) {
        progressHandler = handler
        progressRelay.update(handler)
    }

    /// One item is being dragged; the system asks for delivery now. Stops cleanup from
    /// deleting this item's staged file.
    public func markDelivered(uid: PhotoUID) {
        deliveredUIDs.insert(uid)
        // Promote an already-staged item so cleanup spares its file.
        if case .staged(let url) = jobs[uid] { jobs[uid] = .delivered(url) }
    }

    /// Drag session ended: cancel in-flight work and delete every staged file not marked delivered.
    public func finishAndCleanup() async {
        isCancelled = true
        cancelJobsLocked()
        for (_, state) in jobs {
            // Delivered files belong to the drag destination; cleanup must not touch them.
            if case .staged(let url) = state {
                try? FileManager.default.removeItem(at: url)
            }
        }
        jobs.removeAll()
        queue.removeAll()
        deliveredUIDs.removeAll()
        removeOrphanDownloadFiles()
    }

    /// Cancel everything (drag cancelled) and delete all staged files.
    public func cancelAll() async {
        isCancelled = true
        cancelJobsLocked()
        for (_, state) in jobs {
            switch state {
            case .staged(let url), .delivered(let url?):
                try? FileManager.default.removeItem(at: url)
            default:
                break
            }
        }
        jobs.removeAll()
        queue.removeAll()
        removeOrphanDownloadFiles()
    }

    // MARK: - Internals

    /// Looks up a size via `OriginalFileProvider`'s sibling metadata when the concrete provider
    /// also conforms to `PhotoMetadataProvider`; the stager itself stays provider-agnostic.
    private func size(for item: PhotoItem) -> Int? {
        if let sized = fileProvider as? any SizedOriginalFileProvider {
            return sized.size(of: item.uid)
        }
        return nil
    }

    private func pumpQueue() {
        while runningCount < maxConcurrentWrites, !queue.isEmpty {
            let uid = queue.removeFirst()
            guard let destination = uniqueDownloadURL() else {
                jobs[uid] = .failed(.writeFailed("cannot create staging .download path"))
                continue
            }
            runningCount += 1
            jobs[uid] = .running(Task { await runJob(uid: uid, destination: destination) })
        }
    }

    private func runJob(uid: PhotoUID, destination: URL) async {
        let activity = runtimeState.beginActivity(.userTransfer)
        defer { activity.end() }
        do {
            let relay = progressRelay
            try await fileProvider.writeOriginal(for: uid, to: destination) { fraction in
                relay.emit(uid: uid, fraction: fraction)
            }
            let removesLocation = removeLocationWhenSharing()
            let finalURL = await self.reserveFinalName(
                for: uid, downloadURL: destination, removesLocation: removesLocation)
            do {
                try? FileManager.default.removeItem(at: finalURL)
                let deliveredURL: URL
                if removesLocation {
                    deliveredURL = try await OriginalExportWriter.completeDownloadedOriginal(
                        from: destination, to: finalURL, removeLocation: true)
                    try FileManager.default.removeItem(at: destination)
                } else {
                    try FileManager.default.moveItem(at: destination, to: finalURL)
                    deliveredURL = finalURL
                }
                await self.finishJob(uid: uid, finalURL: deliveredURL, failure: nil)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: finalURL)
                await self.finishJob(
                    uid: uid,
                    finalURL: nil,
                    failure: .writeFailed("rename failed: \(error)")
                )
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            await self.finishJob(uid: uid, finalURL: nil, failure: .cancelled)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            await self.finishJob(uid: uid, finalURL: nil, failure: .writeFailed(String(describing: error)))
        }
    }

    /// Atomic same-volume rename `X.download` → final unique name, reserving the target first.
    private func reserveFinalName(for uid: PhotoUID, downloadURL: URL, removesLocation: Bool) async -> URL {
        let original = await Self.desiredFilename(for: uid, provider: fileProvider)
        // A location-free copy of a RAW photo is a JPEG; reserve that name so it never replaces another file.
        let desired = removesLocation ? LocationSanitizedCopy.outputFilename(forOriginalName: original) : original
        let reserved = await names.unique(desired)
        return stagingDirectory.appendingPathComponent(reserved)
    }

    private func finishJob(
        uid: PhotoUID,
        finalURL: URL?,
        failure: DragOutStagingFailure?
    ) {
        runningCount -= 1
        if let failure {
            // A late cancellation finishes an already-failed/removed job; never resurrect state.
            if case .running = jobs[uid] { jobs[uid] = .failed(failure) }
        } else if let finalURL {
            jobs[uid] = deliveredUIDs.contains(uid) ? .delivered(finalURL) : .staged(finalURL)
        }
        pumpQueue()
    }

    private func cancelJobsLocked() {
        for (uid, state) in jobs {
            if case .running(let task) = state { task.cancel() }
            _ = uid
        }
        runningCount = 0
    }

    private func uniqueDownloadURL() -> URL? {
        stagingDirectory.appendingPathComponent(".\(UUID().uuidString).download")
    }

    private func removeOrphanDownloadFiles() {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: stagingDirectory, includingPropertiesForKeys: nil
            )) ?? []
        for file in files where file.pathExtension == "download" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func desiredFilename(for uid: PhotoUID, provider: any OriginalFileProvider) async -> String {
        var meta: PhotoMetadata?
        if let lookup = provider as? any PhotoMetadataProvider {
            meta = try? await lookup.metadata(for: uid)
        }
        let ext = OriginalFileNaming.resolvedExtension(
            filename: meta?.filename,
            mimeType: meta?.mimeType,
            header: nil,
            fallbackMediaType: meta?.mimeType,
            isVideo: (meta?.mimeType ?? "").hasPrefix("video/")
        )
        let fallbackBase = "Encrypted-Memories-\(uid.nodeID)"
        return OriginalFileNaming.exportFilename(
            metadataFilename: meta?.filename,
            fallbackBase: fallbackBase,
            ext: ext
        )
    }

    /// Serialises unique final-name reservation (case-insensitive, mirroring the platform
    /// exporters) so concurrent stagings cannot clobber each other.
    private let names = UniqueNames()
}

// MARK: - Progress relay

/// Bridges synchronous provider progress callbacks onto the stager actor's current handler.
/// `writeOriginal`'s `onProgress` is a synchronous `@Sendable` closure, so the handler is read
/// atomically here instead of hopping actors per chunk.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (PhotoUID, Double) -> Void)?

    func update(_ handler: (@Sendable (PhotoUID, Double) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func emit(uid: PhotoUID, fraction: Double) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(uid, min(max(fraction, 0), 1))
    }
}

// MARK: - Optional provider conformance seams

/// Optional capability: report a known size for a uid without touching the network. The stager
/// prefers this when computing `totalKnownBytes`; absence simply means unknown.
public protocol SizedOriginalFileProvider: Sendable {
    func size(of uid: PhotoUID) -> Int?
}

// MARK: - Unique naming

/// Serialises on-disk name assignment so two items resolving to the same original name
/// (`IMG_0001.HEIC` twice) get `IMG_0001 2.HEIC` etc. Case-insensitive to match the typical
/// filesystem.
public actor UniqueNames {
    private var used: Set<String> = []

    public init() {}

    public func unique(_ name: String) -> String {
        if reserve(name) { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if reserve(candidate) { return candidate }
            n += 1
        }
    }

    private func reserve(_ name: String) -> Bool {
        guard !used.contains(name.lowercased()) else { return false }
        used.insert(name.lowercased())
        return true
    }
}
