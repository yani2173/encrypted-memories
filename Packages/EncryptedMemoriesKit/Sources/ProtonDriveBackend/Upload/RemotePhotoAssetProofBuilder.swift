import Foundation
import UploadCore

struct DedupeXAttr: Decodable {
    let common: Common?
    let iOSPhotos: IOSPhotos?
    let lineage: Lineage?
    let unreadableLineageMarker: Bool

    enum CodingKeys: String, CodingKey {
        case common = "Common"
        case iOSPhotos = "iOS.photos"
        case lineage = "EncryptedMemories.lineage"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        common = try values.decodeIfPresent(Common.self, forKey: .common)
        iOSPhotos = try values.decodeIfPresent(IOSPhotos.self, forKey: .iOSPhotos)
        if values.contains(.lineage) {
            let decoded = try? values.decode(Lineage.self, forKey: .lineage)
            let readable = decoded?.version == 1 && decoded?.replaces.allSatisfy { !$0.isEmpty } == true
            lineage = readable ? decoded : nil
            unreadableLineageMarker = !readable
        } else {
            lineage = nil
            unreadableLineageMarker = false
        }
    }

    struct Lineage: Decodable {
        let version: Int
        let replaces: [String]

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            replaces = try values.decode([String].self, forKey: .replaces)
        }

        enum CodingKeys: String, CodingKey {
            case version = "V"
            case replaces = "Replaces"
        }
    }

    struct Common: Decodable {
        let digests: Digests?
        enum CodingKeys: String, CodingKey { case digests = "Digests" }

        struct Digests: Decodable {
            let sha1: String?
            enum CodingKeys: String, CodingKey { case sha1 = "SHA1" }
        }
    }

    struct IOSPhotos: Decodable {
        let iCloudID: String?
        let modificationTime: String?
        enum CodingKeys: String, CodingKey {
            case iCloudID = "ICloudID"
            case modificationTime = "ModificationTime"
        }
    }
}

/// Parses the ISO 8601 modification time of `iOS.photos`, with or without fractional seconds. Create one per pass:
/// the formatters are reused for every photo of the pass and are not shared between passes.
struct IOSPhotosModificationTimeParser {
    private let fractional = ISO8601DateFormatter()
    private let standard = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standard.formatOptions = [.withInternetDateTime]
    }

    func date(from raw: String) -> Date? {
        fractional.date(from: raw) ?? standard.date(from: raw)
    }
}

enum RemotePhotoAssetProofBuilder {
    struct Accumulator {
        private let hashKeyEpoch: String
        private var result: [UploadRemoteAssetIndexRecord] = []
        private var seen: Set<UploadBackupExternalIdentity> = []
        private var ambiguous: Set<UploadBackupExternalIdentity> = []

        init(hashKeyEpoch: String) {
            self.hashKeyEpoch = hashKeyEpoch
        }

        mutating func append(
            photos: [PhotosListEntry],
            externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity]
        ) {
            for photo in photos {
                let linkIDs = [photo.linkID] + photo.relatedPhotos.map(\.linkID)
                guard Set(linkIDs).count == linkIDs.count,
                    let identity = externalIdentitiesByLinkID[photo.linkID]
                else {
                    continue
                }
                let allResourcesMatch = linkIDs.allSatisfy { linkID in
                    externalIdentitiesByLinkID[linkID] == identity
                }
                guard allResourcesMatch else { continue }
                guard seen.insert(identity).inserted else {
                    ambiguous.insert(identity)
                    continue
                }
                result.append(
                    UploadRemoteAssetIndexRecord(
                        externalIdentity: identity,
                        resourceCount: linkIDs.count,
                        remoteLinkIDs: linkIDs,
                        hashKeyEpoch: hashKeyEpoch
                    ))
            }
        }

        func finish() -> [UploadRemoteAssetIndexRecord] {
            guard !ambiguous.isEmpty else { return result }
            return result.filter { !ambiguous.contains($0.externalIdentity) }
        }
    }

    static func records(
        photos: [PhotosListEntry],
        externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity],
        hashKeyEpoch: String
    ) -> [UploadRemoteAssetIndexRecord] {
        var accumulator = Accumulator(hashKeyEpoch: hashKeyEpoch)
        accumulator.append(
            photos: photos,
            externalIdentitiesByLinkID: externalIdentitiesByLinkID
        )
        return accumulator.finish()
    }
}
