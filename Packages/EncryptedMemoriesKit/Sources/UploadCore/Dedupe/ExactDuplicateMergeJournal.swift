import Foundation

/// A merge of exact duplicates that moved photos to the trash and has not confirmed an active copy of its group yet.
/// The merge records it before its trash. When the merge fails or the process ends before its check, the next scan or
/// merge reads the group again and restores a copy when none stayed.
public struct ExactDuplicateMergeIntent: Sendable, Equatable, Codable {
    /// One photo that the trash of the merge takes, with the manifest rows that moved from it to the kept photo.
    public struct Member: Sendable, Equatable, Codable {
        public let link: String
        public let moves: [UploadRemoteLinkMove]
    }

    public let volumeID: String
    /// The link of the photo to keep.
    public let kept: String
    public let contentHash: String
    public let hashKeyEpoch: String
    public let members: [Member]
    /// The device clock at the trash, in seconds since 1970. It dates the trash of the merge when the server no longer
    /// knows the trashed members, for example after the person emptied the trash. Nil in records without the time.
    public let trashedAt: Int64?
    /// The active main photos whose lineage named the kept photo as replaced before the trash. Such an edit cannot be
    /// the reason why the kept photo left the library later. Nil when the read failed, and in records without it.
    public var successors: [String]? = nil

    /// One intent for each group: the kept photo and the content of the group.
    var key: String { kept + "|" + contentHash }
}

/// Whether a merge can record its trash.
public enum ExactDuplicateMergeJournalState: Sendable, Equatable {
    case ready
    /// The journal file held no intents that decode. It moved aside under another name, and a new file starts.
    case replacedUnreadable
    /// The journal could not be read or written, for example after an I/O error. It stays as it is, and a merge must
    /// not start its writes.
    case unavailable
}

/// The merges that wait for the check of their kept photo.
public protocol ExactDuplicateMergeJournaling: Sendable {
    /// Makes sure that the next `record` can succeed, before the merge writes anything else.
    func prepareForWrites() -> ExactDuplicateMergeJournalState
    /// Nil when the journal cannot be read.
    func pendingMerges() -> [ExactDuplicateMergeIntent]?
    /// Records `intents` in place of earlier intents of the same groups. False when the write failed.
    func record(_ intents: [ExactDuplicateMergeIntent]) -> Bool
    /// Removes exactly these intents. A newer intent of the same group, which a later merge recorded meanwhile, stays for
    /// its own check. False when the write failed.
    func clear(_ intents: [ExactDuplicateMergeIntent]) -> Bool
}

extension ExactDuplicateMergeJournaling {
    /// True only when the journal is readable and holds no merge. A file that does not decode protects nothing, so it is
    /// moved aside as before a merge: this answer stays false, and the next one can be true. A file that cannot be read
    /// stays, because it can hold merges.
    func confirmsNoOpenMerge() -> Bool {
        guard let pending = pendingMerges() else {
            _ = prepareForWrites()
            return false
        }
        return pending.isEmpty
    }
}

/// The journal of the account in one small JSON file, `fileName`, next to the upload manifest. A sign-out removes it
/// with the account's other files. Each call reads the file again, so two stores of one file agree.
public final class ExactDuplicateMergeJournalFileStore: ExactDuplicateMergeJournaling {
    public static let fileName = "exact-duplicate-merge-intents-v1.json"

    /// Serializes the writes of every store in the process.
    private static let lock = NSLock()
    private let url: URL

    public init(accountDataDirectory: URL) {
        url = accountDataDirectory.appendingPathComponent(Self.fileName)
    }

    public func pendingMerges() -> [ExactDuplicateMergeIntent]? {
        Self.lock.withLock { read().intents }
    }

    /// Moves a file that does not decode aside, so a damaged file never blocks every later merge. The moved file stays
    /// in the account folder for diagnostics. A file that cannot be read stays, because it can hold intents.
    public func prepareForWrites() -> ExactDuplicateMergeJournalState {
        Self.lock.withLock {
            var state = ExactDuplicateMergeJournalState.ready
            switch read() {
            case .absent, .decoded: break
            case .unavailable: return .unavailable
            case .damaged:
                let aside = url.deletingLastPathComponent().appendingPathComponent(
                    "exact-duplicate-merge-intents-v1.unreadable-\(UUID().uuidString).json")
                guard (try? FileManager.default.moveItem(at: url, to: aside)) != nil else { return .unavailable }
                state = .replacedUnreadable
            }
            guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                return .unavailable
            }
            return state
        }
    }

    public func record(_ intents: [ExactDuplicateMergeIntent]) -> Bool {
        let keys = Set(intents.map(\.key))
        return update { $0 = $0.filter { !keys.contains($0.key) } + intents }
    }

    public func clear(_ intents: [ExactDuplicateMergeIntent]) -> Bool {
        update { $0.removeAll { intents.contains($0) } }
    }

    private enum Read {
        /// No file: no merge waits.
        case absent
        case decoded([ExactDuplicateMergeIntent])
        /// The file was read and does not decode.
        case damaged
        /// The file could not be read. It can hold intents.
        case unavailable

        var intents: [ExactDuplicateMergeIntent]? {
            switch self {
            case .absent: []
            case .decoded(let intents): intents
            case .damaged, .unavailable: nil
            }
        }
    }

    /// Reads the file directly: a failed lookup of `fileExists` also reports a missing file.
    private func read() -> Read {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return Self.isMissingFile(error) ? .absent : .unavailable
        }
        guard let intents = try? JSONDecoder().decode([ExactDuplicateMergeIntent].self, from: data) else {
            return .damaged
        }
        return .decoded(intents)
    }

    private static func isMissingFile(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
        {
            return true
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    /// Writes only after a read that found no file or decoded it, so a failed read never replaces pending intents.
    private func update(_ change: (inout [ExactDuplicateMergeIntent]) -> Void) -> Bool {
        Self.lock.withLock {
            guard var intents = read().intents else { return false }
            let before = intents
            change(&intents)
            guard intents != before else { return true }
            guard !intents.isEmpty else {
                do {
                    try FileManager.default.removeItem(at: url)
                    return true
                } catch {
                    return Self.isMissingFile(error)
                }
            }
            guard let data = try? JSONEncoder().encode(intents) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }
    }
}
