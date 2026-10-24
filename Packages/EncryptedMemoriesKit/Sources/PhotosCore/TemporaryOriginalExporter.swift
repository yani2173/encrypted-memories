import Foundation

/// Stages temporary originals for a native share presentation. Each job owns a UUID directory and reserves
/// names independently. The caller owns successful files until presentation ends and invokes `cleanup` then.
public struct TemporaryOriginalExporter: Sendable {
    private let configuredExportRoot: URL?

    public init(exportRoot: URL? = nil) {
        self.configuredExportRoot = exportRoot
    }

    /// Resolve the default root only when a job needs it, after the empty-input and cancellation checks.
    private var exportRoot: URL {
        configuredExportRoot
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShareExports", isDirectory: true)
    }

    /// Returns a new owned path without creating it. Support reports use the same ownership boundary.
    public func makeExportDirectory() -> URL {
        exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Share completion deletes only its own files. It never removes the shared root or another job.
    public func cleanup(_ urls: [URL]) {
        let root = exportRoot.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        var parents = Set<URL>()
        for url in urls {
            let file = url.standardizedFileURL
            let parent = file.deletingLastPathComponent()
            let resolvedParent = parent.resolvingSymlinksInPath()
            let isLegacyFile = parent == root && resolvedParent == resolvedRoot
            let isOwnedChild =
                parent.deletingLastPathComponent() == root
                && UUID(uuidString: parent.lastPathComponent) != nil
                && resolvedParent.deletingLastPathComponent() == resolvedRoot
                && resolvedParent.lastPathComponent == parent.lastPathComponent
            guard isLegacyFile || isOwnedChild else { continue }
            try? FileManager.default.removeItem(at: file)
            if isOwnedChild { parents.insert(parent) }
        }
        for parent in parents {
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    /// The result of an export run: successfully written URLs, the count of items left out, and whether
    /// the device ran short of space.
    public struct ExportResult: Sendable {
        public let urls: [URL]
        public let failed: Int
        public var ranOutOfSpace = false
    }

    public func exportOriginals(
        _ items: [PhotoItem],
        backend: any OriginalFileProvider & PhotoMetadataProvider,
        runtimeState: LibraryRuntimeState = .shared,
        availableCapacity: (URL) -> Int64? = DeviceStorage.availableCapacity(at:),
        removeLocationWhenSharing: () -> Bool = { PrivacyExportPolicy.isEnabled() }
    ) async -> ExportResult {
        guard !items.isEmpty else { return ExportResult(urls: [], failed: 0) }
        guard !Task.isCancelled else { return ExportResult(urls: [], failed: items.count) }
        let activity = runtimeState.beginActivity(.userTransfer)
        defer { activity.end() }
        let directory = makeExportDirectory()
        let directoryReady = await Task.detached(priority: .utility) {
            let files = FileManager.default
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                return true
            } catch {
                return false
            }
        }.value
        guard directoryReady else { return ExportResult(urls: [], failed: items.count) }

        // Two selected photos can share an original Proton name. Reserve a unique path before writing
        // so concurrent exports cannot overwrite each other.
        let names = UniqueNames()
        let removesLocation = removeLocationWhenSharing()

        let maxConcurrent = 2
        var exported: [URL] = []
        var index = 0
        var ranOutOfSpace = false
        // Original sizes are unknown up front, so each next item needs the reserve free before it starts. The rest
        // of the selection is then reported as a space failure instead of filling the device.
        func hasRoomForNextItem() -> Bool {
            (availableCapacity(directory) ?? .max) >= Self.exportReserveBytes
        }
        // Bounded task group: at most `maxConcurrent` downloads in flight so a big video selection can't spike RAM.
        await withTaskGroup(of: ItemExport.self) { group in
            func addNext() {
                guard index < items.count, !Task.isCancelled, !ranOutOfSpace else { return }
                guard hasRoomForNextItem() else {
                    ranOutOfSpace = true
                    return
                }
                let item = items[index]
                index += 1
                group.addTask {
                    await Self.export(
                        item, backend: backend, names: names, into: directory,
                        removeLocationWhenSharing: removesLocation)
                }
            }
            for _ in 0..<min(maxConcurrent, items.count) { addNext() }
            for await outcome in group {
                switch outcome {
                case .exported(let url): exported.append(url)
                // A full device fails every later item too. Stop instead of retrying into the same wall.
                case .outOfSpace: ranOutOfSpace = true
                case .failed: break
                }
                addNext()
            }
        }
        if Task.isCancelled {
            cleanup(exported)
            try? FileManager.default.removeItem(at: directory)
            return ExportResult(urls: [], failed: items.count)
        }
        if exported.isEmpty { try? FileManager.default.removeItem(at: directory) }
        return ExportResult(urls: exported, failed: items.count - exported.count, ranOutOfSpace: ranOutOfSpace)
    }

    /// Free space an export leaves untouched, matching the drag-out staging reserve.
    private static let exportReserveBytes: Int64 = 128 * 1024 * 1024

    private enum ItemExport: Sendable {
        case exported(URL)
        case outOfSpace
        case failed
    }

    private static func export(
        _ item: PhotoItem,
        backend: any OriginalFileProvider & PhotoMetadataProvider,
        names: UniqueNames,
        into directory: URL,
        removeLocationWhenSharing: Bool
    ) async -> ItemExport {
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try Task.checkCancellation()
            try await backend.writeOriginal(for: item.uid, to: staging)
            try Task.checkCancellation()
            // The decrypted Proton filename is authoritative. Preserve it when available, and use the
            // generated fallback if metadata lookup fails.
            let meta = try? await backend.metadata(for: item.uid)
            // Derive a missing extension from the bounded header, then use the link MIME as a secondary signal.
            let desired = try OriginalExportWriter.exportFilename(
                forDownloadedOriginal: staging, item: item, metadata: meta, fallbackBase: Self.fallbackBase(for: item)
            )
            // A location-free copy of a RAW photo is a JPEG; reserve that name so it never replaces another file.
            let name =
                removeLocationWhenSharing ? LocationSanitizedCopy.outputFilename(forOriginalName: desired) : desired
            let url = directory.appendingPathComponent(await names.unique(name))
            try Task.checkCancellation()
            return .exported(
                try await OriginalExportWriter.completeDownloadedOriginal(
                    from: staging, to: url, removeLocation: removeLocationWhenSharing))
        } catch {
            return DeviceStorage.isOutOfSpace(error) ? .outOfSpace : .failed
        }
    }

    /// Generates a fallback base name when Proton metadata has no filename. The timestamp and node suffix
    /// avoid collisions before the unique-name actor assigns the final path.
    private static func fallbackBase(for item: PhotoItem) -> String {
        let stamp = Self.stampFormatter.string(from: item.captureTime)
        let suffix = String(item.uid.nodeID.suffix(6))
        return "Encrypted-Memories-\(stamp)-\(suffix)"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
