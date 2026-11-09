import CryptoKit
import Foundation
import PhotosCore

/// Durable record of one revert to original of an edited photo.
///
/// Proton Drive cannot re-attach a related file as a standalone photo. The revert therefore copies the hidden
/// original into a new standalone photo, carries the edited photo's favorite tag and own albums over, and then
/// moves only the edited photo to the trash with its related files. The journal is written before each remote
/// step, so a crash at any point resumes without a duplicate copy and never trashes the edited photo before
/// the restored copy exists.
public struct EditedOriginalRevertJournal: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// The restored copy may not exist yet. The edited photo is untouched.
        case copying
        /// The restored copy is confirmed and carries the edited photo's favorite tag and own albums. The
        /// edited photo may move to the trash.
        case trashingEdit
        /// The edited photo is confirmed in the trash. Only the device-side state (backup states, upload
        /// manifest) may still point at it; no server write remains.
        case repointingDevice
    }

    /// The edited photo whose original the revert restores.
    public let editedMainUID: PhotoUID
    /// The related file of `editedMainUID` that holds the original bytes.
    public let originalLinkID: String
    /// The name under which the restored copy is uploaded. A resume that must make the copy again needs it.
    public var restoredName: String?
    /// The standalone photo that holds the restored original. Nil until it is confirmed.
    public var copyUID: PhotoUID?
    /// True once the copy carries the edited photo's favorite tag. The tag is written once.
    public var favoriteDone: Bool
    /// Albums of the own library that already contain the copy. One entry per confirmed album write.
    public var addedAlbumIDs: [String]
    public var phase: Phase

    public init(
        editedMainUID: PhotoUID,
        originalLinkID: String,
        restoredName: String? = nil,
        copyUID: PhotoUID? = nil,
        favoriteDone: Bool = false,
        addedAlbumIDs: [String] = [],
        phase: Phase = .copying
    ) {
        self.editedMainUID = editedMainUID
        self.originalLinkID = originalLinkID
        self.restoredName = restoredName
        self.copyUID = copyUID
        self.favoriteDone = favoriteDone
        self.addedAlbumIDs = addedAlbumIDs
        self.phase = phase
    }

    // An app update can meet a journal that an older build wrote without the carry-over fields. Their
    // absence means "nothing carried over yet", which is the safe state for a resume.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        editedMainUID = try container.decode(PhotoUID.self, forKey: .editedMainUID)
        originalLinkID = try container.decode(String.self, forKey: .originalLinkID)
        restoredName = try container.decodeIfPresent(String.self, forKey: .restoredName)
        copyUID = try container.decodeIfPresent(PhotoUID.self, forKey: .copyUID)
        favoriteDone = try container.decodeIfPresent(Bool.self, forKey: .favoriteDone) ?? false
        addedAlbumIDs = try container.decodeIfPresent([String].self, forKey: .addedAlbumIDs) ?? []
        phase = try container.decode(Phase.self, forKey: .phase)
    }
}

/// Persistence seam of the revert journal. `save` must be atomic before it returns, so the write survives a
/// process crash. Power-loss durability is the host file system's, not a promise of this seam.
public protocol EditedOriginalRevertJournalStore: Sendable {
    func journal(forEditedMain mainUID: PhotoUID) throws -> EditedOriginalRevertJournal?
    /// Same as `journal`, except a file that exists but cannot be decoded counts as missing. `revert` and
    /// `abandon` use it, so an undecodable journal is not a dead end for its photo: `revert` starts a
    /// fresh run over it, and `abandon` removes the file. A file that cannot be read still throws.
    func decodableJournal(forEditedMain mainUID: PhotoUID) throws -> EditedOriginalRevertJournal?
    func save(_ journal: EditedOriginalRevertJournal) throws
    func remove(forEditedMain mainUID: PhotoUID) throws
    /// Operations that a crash or an error interrupted. After account activation the host resumes only
    /// those in the trash step; one that still copies waits for the person.
    func pendingJournals() throws -> [EditedOriginalRevertJournal]
}

/// One JSON file per edited photo in the account data directory, replaced atomically. The sign-out purge removes
/// the directory with the rest of the account data. A file holds node identifiers only, never names or bytes.
public struct EditedOriginalRevertJournalFileStore: EditedOriginalRevertJournalStore {
    public static let directoryName = "edited-original-revert"

    private let directory: URL

    public init(accountDataDirectory: URL) {
        directory = accountDataDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public func journal(forEditedMain mainUID: PhotoUID) throws -> EditedOriginalRevertJournal? {
        let url = fileURL(for: mainUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(EditedOriginalRevertJournal.self, from: Data(contentsOf: url))
    }

    public func decodableJournal(forEditedMain mainUID: PhotoUID) throws -> EditedOriginalRevertJournal? {
        let url = fileURL(for: mainUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A read error still throws: only a file that was read but cannot be decoded counts as missing.
        let data = try Data(contentsOf: url)
        return try? JSONDecoder().decode(EditedOriginalRevertJournal.self, from: data)
    }

    public func save(_ journal: EditedOriginalRevertJournal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: fileURL(for: journal.editedMainUID), options: .atomic)
    }

    public func remove(forEditedMain mainUID: PhotoUID) throws {
        let url = fileURL(for: mainUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func pendingJournals() throws -> [EditedOriginalRevertJournal] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var pending: [EditedOriginalRevertJournal] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            let data = try Data(contentsOf: url)
            // Undecodable but readable content skips only this journal: its edited photo stays untouched in
            // the library. The photo is not stuck: `revert` starts a fresh run over the undecodable file, and
            // `abandon` removes it.
            if let journal = try? JSONDecoder().decode(EditedOriginalRevertJournal.self, from: data) {
                pending.append(journal)
            }
        }
        return pending
    }

    private func fileURL(for mainUID: PhotoUID) -> URL {
        let digest = SHA256.hash(data: Data("\(mainUID.volumeID)/\(mainUID.nodeID)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}
