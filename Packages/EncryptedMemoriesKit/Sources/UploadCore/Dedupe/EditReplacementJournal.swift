import Foundation
import PhotosCore

/// The earlier uploads of one photo-library primary after the person edited the photo.
public struct EditReplacementJournalEntry: Sendable, Equatable, Codable {
    /// Photos that held earlier bytes of this primary. The backup moves them to the trash after the edited photo and
    /// its secondaries are uploaded.
    public var superseded: [PhotoUID]
    /// Targets discovered only through the optional remote index. An incomplete read must keep these targets. They
    /// stay out of `superseded`, which earlier app versions read: those versions lack the guards that prove them.
    public var remoteSuperseded: [String]?
    /// Links the backup already moved to the trash, with their related photos. A trashed copy among them is no
    /// deletion by the person.
    public var retired: [String]
    /// True when the last upload of this photo was an edit. Only then do other bytes of the unedited photo undo an
    /// edit. Nil in journals of earlier builds.
    public var uploadedEdit: Bool?
    /// Related links by earlier main, recorded before its trash. Nil in journals of earlier builds.
    public var retireIntent: [String: [String]]?
    /// Main links of `superseded`, `remoteSuperseded`, and `retired` that are proven earlier uploads of this photo:
    /// its own uploads, and links with its iCloud identifier. Only these links appear in the lineage marker, and only
    /// these local targets move to the trash without a twin check of their files. Nil in journals of earlier builds,
    /// so their links stay unnamed and need that check.
    public var proven: [String]?
    /// The uploads that a proven remote photo replaced, by that photo, as its lineage named them.
    public var inherited: [String: [String]]?
    /// Earlier mains that left the library without a trash by a backup, for example by the person. The backup
    /// never trashes them again, and a trashed copy among them is no deletion proof. Nil in journals of earlier
    /// builds.
    public var gone: [String]?

    /// The person's deletion choice and a wait that survives queue retries and process death.
    public var keptDeleted: Bool?
    public var backUpAgainRevision: UploadBackupRevision?
    public var deletionCheckStartedAt: Date?

    public init(
        superseded: [PhotoUID] = [], retired: [String] = [], uploadedEdit: Bool? = nil,
        retireIntent: [String: [String]]? = nil, remoteSuperseded: [String]? = nil,
        keptDeleted: Bool? = nil, backUpAgainRevision: UploadBackupRevision? = nil,
        deletionCheckStartedAt: Date? = nil, proven: [String]? = nil, inherited: [String: [String]]? = nil,
        gone: [String]? = nil
    ) {
        self.superseded = superseded
        self.remoteSuperseded = remoteSuperseded
        self.retired = retired
        self.uploadedEdit = uploadedEdit
        self.retireIntent = retireIntent
        self.gone = gone
        self.keptDeleted = keptDeleted
        self.backUpAgainRevision = backUpAgainRevision
        self.deletionCheckStartedAt = deletionCheckStartedAt
        self.proven = proven
        self.inherited = inherited
    }

    /// Without the flag, a photo that already replaced an earlier upload counts as edited: only edits and undos
    /// replaced photos in earlier builds.
    public var lastUploadWasEdit: Bool { uploadedEdit ?? !retired.isEmpty }

    /// Other bytes replace the earlier uploads only as an edit or as the undo of an edit.
    public func replacesEarlierUploads(edited: Bool) -> Bool { edited || lastUploadWasEdit }

    /// The proven earlier uploads, newest first: the links that the next upload replaces, then the retired links.
    /// The uploads that a remote photo replaced follow it as one group without inner order. Empty when no proven link
    /// waits for its replacement. Related links and unproven links, such as an adopted copy without an iCloud
    /// identifier, never appear: a missing name only costs another device its proof, a wrong name costs a photo.
    public func replacementHistory(excluding foreign: Set<String>) -> [[String]] {
        let proven = Set(proven ?? [])
        func groups(_ links: [String]) -> [[String]] {
            links.reversed().filter { proven.contains($0) && !foreign.contains($0) }.flatMap { link in
                [[link]] + (inherited?[link].map { [$0.filter { !foreign.contains($0) }] } ?? [])
            }
        }
        let replaced = groups(allSuperseded.map(\.nodeID))
        return replaced.isEmpty ? [] : replaced + groups(retired)
    }

    /// Local and remote targets of the replacement.
    public var allSuperseded: [PhotoUID] {
        superseded
            + (remoteSuperseded ?? []).filter { id in !superseded.contains { $0.nodeID == id } }
            .map { PhotoUID(volumeID: "", nodeID: $0) }
    }

    /// Every link that the entry names: targets, retired links, related links of an intent, proven links, and the
    /// uploads that they replaced.
    public var namedLinkIDs: Set<String> {
        var links = Set(allSuperseded.map(\.nodeID)).union(retired).union(proven ?? [])
        for (main, related) in retireIntent ?? [:] {
            links.insert(main)
            links.formUnion(related)
        }
        for (main, replaced) in inherited ?? [:] {
            links.insert(main)
            links.formUnion(replaced)
        }
        return links
    }

    public var isEmpty: Bool {
        allSuperseded.isEmpty && retired.isEmpty && uploadedEdit != true && (retireIntent?.isEmpty ?? true)
            && (gone?.isEmpty ?? true) && keptDeleted != true && backUpAgainRevision == nil
            && deletionCheckStartedAt == nil
    }
}

/// Durable record of edited photos that replace their earlier upload. The dedupe pipeline adds the earlier
/// photo before its manifest record forgets it; the backup runner retires it after the trash write.
public protocol EditReplacementJournaling: Sendable {
    func keepDeleted(for source: UploadSourceIdentity) throws
    func backUpAgain(revision: UploadBackupRevision, for source: UploadSourceIdentity) throws
    func startDeletionCheck(at date: Date, for source: UploadSourceIdentity) throws
    func clearDeletionCheck(for source: UploadSourceIdentity) throws
    func clearDeletionChoice(for source: UploadSourceIdentity) throws
    func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry
    /// One in-memory snapshot for admission after a queue reset, without reading each queued source.
    func supersededSourceIdentifiers() -> Set<String>
    func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws
    /// Adds a target that requires a complete index read before retirement. Existing local targets stay local.
    func addRemoteSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws
    /// Marks a superseded main as a proven earlier upload, with the uploads that it replaced. Call it after the link
    /// joins the targets: an entry without targets keeps no proof.
    func addProven(_ nodeID: String, inherited: [String], for source: UploadSourceIdentity) throws
    /// Records related links before trashing their mains, without retiring active links.
    func prepareToRetire(_ relatedByMain: [String: [String]], for source: UploadSourceIdentity) throws
    /// Clears an earlier intent when a retry confirms that its main is still active.
    func clearRetireIntent(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws
    /// Removes the photos from `superseded`. With `trashed` true they and `related` join `retired`.
    func settle(_ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity) throws
    /// Removes the photos from `superseded` and records them in `gone`, never in `retired`: no backup trashed them.
    func settleGone(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws
    /// Records whether the upload that the backup finished for `source` was an edit.
    func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws
    /// Removes photos from `retired`: the person restored them, so they are in the library again.
    func unretire(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws
    /// True when an entry names one of `linkIDs`. The edit replacement still owns such a link, so the merge of exact
    /// duplicates leaves it.
    func namesAnyLink(_ linkIDs: Set<String>) -> Bool
}

extension EditReplacementJournaling {
    public func supersededSourceIdentifiers() -> Set<String> { [] }
    /// A journal that cannot list its links protects every link.
    public func namesAnyLink(_ linkIDs: Set<String>) -> Bool { true }
}

/// A log of JSON lines in the account data directory, so the sign-out purge removes it with the other stores. Each
/// change appends the new entry of one source, so a change costs one short line, also with thousands of edited
/// photos. The log is rewritten from the entries when it holds many more lines than entries. Retired links stay
/// without a limit: each edit adds only a few, and a dropped one could hide an undo.
public final class EditReplacementJournalFileStore: EditReplacementJournaling, @unchecked Sendable {
    /// The single JSON file of earlier builds. A store without a log reads it once and continues in the log.
    public static let fileName = "edit-replacement-journal-v1.json"
    public static let logFileName = "edit-replacement-journal-v2.jsonl"

    private struct Line: Codable {
        let key: String
        /// Nil when the entry of `key` became empty.
        let entry: EditReplacementJournalEntry?
    }

    /// Written in place of the file of earlier builds. An earlier build cannot read it and keeps earlier uploads,
    /// instead of replacing photos without the history that only the log holds.
    static let earlierBuildBarrier = Data(#"{"movedTo":"edit-replacement-journal-v2.jsonl"}"#.utf8)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: WeakStore] = [:]

    private struct WeakStore {
        weak var store: EditReplacementJournalFileStore?
    }

    /// One store for each journal in the process. Two stores of one log would write over each other's lines.
    /// Nil when the journal exists but cannot be read.
    public static func shared(accountDataDirectory: URL) -> EditReplacementJournalFileStore? {
        let key = accountDataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return registryLock.withLock {
            if let store = registry[key]?.store { return store }
            guard let store = EditReplacementJournalFileStore(accountDataDirectory: accountDataDirectory) else {
                return nil
            }
            registry[key] = WeakStore(store: store)
            SupportDiagnosticsSources.shared.registerEditReplacements(store, key: key)
            return store
        }
    }

    private let logURL: URL
    private let lock = NSLock()
    private var entries: [String: EditReplacementJournalEntry]
    private var lineCount: Int
    /// Set when a failed write could not be undone. The log then accepts no further line.
    private var writeFailed = false

    /// Nil when the journal exists but cannot be read. Edits then keep their earlier uploads instead of losing the
    /// photos that still wait for their replacement. The app opens it through `shared(accountDataDirectory:)`.
    init?(accountDataDirectory: URL) {
        let logURL = accountDataDirectory.appendingPathComponent(Self.logFileName)
        self.logURL = logURL
        let earlierURL = accountDataDirectory.appendingPathComponent(Self.fileName)
        defer { Self.placeBarrier(at: earlierURL, whenLogExists: logURL) }
        if FileManager.default.fileExists(atPath: logURL.path) {
            guard let data = try? Data(contentsOf: logURL), let replay = Self.replay(data) else { return nil }
            entries = replay.entries
            lineCount = replay.lines
            // A write that stopped halfway leaves a line without its end. The next line would join it.
            if replay.tornTail {
                guard (try? rewrite()) != nil else { return nil }
            }
        } else if FileManager.default.fileExists(atPath: earlierURL.path) {
            guard let data = try? Data(contentsOf: earlierURL),
                let decoded = try? JSONDecoder().decode([String: EditReplacementJournalEntry].self, from: data)
            else { return nil }
            entries = decoded
            lineCount = 0
            guard (try? rewrite()) != nil else { return nil }
        } else {
            entries = [:]
            lineCount = 0
        }
    }

    /// Keeps earlier builds away from the log's history once the log exists.
    private static func placeBarrier(at earlierURL: URL, whenLogExists logURL: URL) {
        guard FileManager.default.fileExists(atPath: logURL.path),
            (try? Data(contentsOf: earlierURL)) != earlierBuildBarrier
        else { return }
        try? earlierBuildBarrier.write(to: earlierURL, options: .atomic)
    }

    private static func replay(
        _ data: Data
    ) -> (entries: [String: EditReplacementJournalEntry], lines: Int, tornTail: Bool)? {
        var entries: [String: EditReplacementJournalEntry] = [:]
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let tornTail = !data.isEmpty && data.last != UInt8(ascii: "\n")
        let decoder = JSONDecoder()
        for (index, line) in lines.enumerated() {
            guard let decoded = try? decoder.decode(Line.self, from: Data(line)) else {
                // Only the last line can be cut off by a stop during a write. Any other broken line is damage.
                guard tornTail, index == lines.count - 1 else { return nil }
                return (entries, index, true)
            }
            entries[decoded.key] = decoded.entry
        }
        return (entries, lines.count, tornTail)
    }

    public func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry {
        lock.withLock { entries[Self.key(source)] ?? EditReplacementJournalEntry() }
    }

    public func namesAnyLink(_ linkIDs: Set<String>) -> Bool {
        guard !linkIDs.isEmpty else { return false }
        return lock.withLock { entries.values.contains { !$0.namedLinkIDs.isDisjoint(with: linkIDs) } }
    }

    public func supersededSourceIdentifiers() -> Set<String> {
        let prefix = UploadSourceIdentity.Kind.photoLibraryAsset.rawValue + "|"
        let suffix = "|" + UploadSourceIdentity.Resource.primary.rawValue
        return lock.withLock {
            Set(
                entries.compactMap { key, entry in
                    guard !entry.allSuperseded.isEmpty, key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
                    return String(key.dropFirst(prefix.count).dropLast(suffix.count))
                })
        }
    }

    public func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            guard !entry.superseded.contains(where: { $0.nodeID == uid.nodeID }) else { return }
            entry.superseded.append(uid)
        }
    }

    public func addRemoteSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            guard !entry.allSuperseded.contains(where: { $0.nodeID == uid.nodeID }) else { return }
            entry.remoteSuperseded = (entry.remoteSuperseded ?? []) + [uid.nodeID]
        }
    }

    public func addProven(_ nodeID: String, inherited: [String], for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            if entry.proven?.contains(nodeID) != true { entry.proven = (entry.proven ?? []) + [nodeID] }
            guard !inherited.isEmpty else { return }
            var byLink = entry.inherited ?? [:]
            byLink[nodeID] = inherited.sorted()
            entry.inherited = byLink
        }
    }

    public func prepareToRetire(_ relatedByMain: [String: [String]], for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            var intent = entry.retireIntent ?? [:]
            for (main, related) in relatedByMain { intent[main] = related.sorted() }
            entry.retireIntent = intent.isEmpty ? nil : intent
        }
    }

    public func clearRetireIntent(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            for nodeID in nodeIDs { entry.retireIntent?[nodeID] = nil }
            if entry.retireIntent?.isEmpty == true { entry.retireIntent = nil }
        }
    }

    public func settle(
        _ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity
    ) throws {
        try update(source) { entry in
            // The journal added its targets in the order of their history.
            let mains = entry.allSuperseded.map(\.nodeID).filter(nodeIDs.contains)
            entry.superseded.removeAll { nodeIDs.contains($0.nodeID) }
            entry.remoteSuperseded?.removeAll(where: nodeIDs.contains)
            if entry.remoteSuperseded?.isEmpty == true { entry.remoteSuperseded = nil }
            var confirmedRelated = related
            for nodeID in nodeIDs {
                if trashed { confirmedRelated.formUnion(entry.retireIntent?[nodeID] ?? []) }
                entry.retireIntent?[nodeID] = nil
            }
            if entry.retireIntent?.isEmpty == true { entry.retireIntent = nil }
            guard trashed else {
                // A kept link is no replaced upload, and a foreign one never was one.
                entry.proven?.removeAll(where: nodeIDs.contains)
                if entry.proven?.isEmpty == true { entry.proven = nil }
                for nodeID in nodeIDs { entry.inherited?[nodeID] = nil }
                if entry.inherited?.isEmpty == true { entry.inherited = nil }
                return
            }
            let ordered = mains + nodeIDs.subtracting(mains).sorted() + confirmedRelated.subtracting(nodeIDs).sorted()
            for linkID in ordered where !entry.retired.contains(linkID) {
                entry.retired.append(linkID)
            }
        }
    }

    public func settleGone(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        guard !nodeIDs.isEmpty else { return }
        try update(source) { entry in
            entry.superseded.removeAll { nodeIDs.contains($0.nodeID) }
            entry.remoteSuperseded?.removeAll(where: nodeIDs.contains)
            if entry.remoteSuperseded?.isEmpty == true { entry.remoteSuperseded = nil }
            for nodeID in nodeIDs { entry.retireIntent?[nodeID] = nil }
            if entry.retireIntent?.isEmpty == true { entry.retireIntent = nil }
            var gone = entry.gone ?? []
            for linkID in nodeIDs.sorted() where !gone.contains(linkID) && !entry.retired.contains(linkID) {
                gone.append(linkID)
            }
            entry.gone = gone.isEmpty ? nil : gone
        }
    }

    public func keepDeleted(for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            entry.keptDeleted = true
            entry.backUpAgainRevision = nil
            entry.deletionCheckStartedAt = nil
        }
    }

    public func backUpAgain(revision: UploadBackupRevision, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            entry.keptDeleted = nil
            entry.backUpAgainRevision = revision
            entry.deletionCheckStartedAt = nil
        }
    }

    public func startDeletionCheck(at date: Date, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            if entry.deletionCheckStartedAt == nil { entry.deletionCheckStartedAt = date }
        }
    }

    public func clearDeletionCheck(for source: UploadSourceIdentity) throws {
        try update(source) { entry in entry.deletionCheckStartedAt = nil }
    }

    public func clearDeletionChoice(for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            entry.keptDeleted = nil
            entry.backUpAgainRevision = nil
            entry.deletionCheckStartedAt = nil
        }
    }

    public func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            // An unedited photo without other entries needs no flag: nil counts as unedited then.
            entry.uploadedEdit = edited || !entry.retired.isEmpty ? edited : nil
        }
    }

    public func unretire(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        try update(source) { entry in entry.retired.removeAll(where: nodeIDs.contains) }
    }

    private func update(_ source: UploadSourceIdentity, _ change: (inout EditReplacementJournalEntry) -> Void) throws {
        try lock.withLock {
            let key = Self.key(source)
            var entry = entries[key] ?? EditReplacementJournalEntry()
            change(&entry)
            let next = entry.isEmpty ? nil : entry
            guard next != entries[key] else { return }
            try append(Line(key: key, entry: next))
            entries[key] = next
            lineCount += 1
            if lineCount > max(1_000, entries.count * 2) { try rewrite() }
        }
    }

    private func append(_ line: Line) throws {
        guard !writeFailed else { throw UploadError.backend("Edit replacement journal could not be written") }
        var data = try JSONEncoder().encode(line)
        data.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try data.write(to: logURL, options: .atomic)
            Self.placeBarrier(
                at: logURL.deletingLastPathComponent().appendingPathComponent(Self.fileName), whenLogExists: logURL)
            return
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A part of the line may be in the file, for example when the disk filled up. The next line would join
            // it, so the log goes back to its length before this write.
            do {
                try handle.truncate(atOffset: end)
            } catch {
                writeFailed = true
            }
            throw error
        }
    }

    /// Replaces the log with one line for each entry, in one atomic write.
    private func rewrite() throws {
        let encoder = JSONEncoder()
        var data = Data()
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
            data.append(try encoder.encode(Line(key: key, entry: entry)))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: logURL, options: .atomic)
        lineCount = entries.count
    }

    private static func key(_ source: UploadSourceIdentity) -> String {
        "\(source.kind.rawValue)|\(source.identifier)|\(source.resource.rawValue)"
    }
}

extension EditReplacementJournalFileStore: EditReplacementSupportSource {
    public func editReplacementSupportSnapshot() -> EditReplacementSupportSnapshot {
        lock.withLock {
            var result = EditReplacementSupportSnapshot()
            for entry in entries.values {
                if !entry.allSuperseded.isEmpty { result.sourcesWithSupersededEntries += 1 }
                result.totalSuperseded += entry.allSuperseded.count
                result.totalRetired += entry.retired.count
                if !(entry.retireIntent?.isEmpty ?? true) { result.rowsWithRetireIntent += 1 }
            }
            return result
        }
    }
}
