import Foundation
import PhotosCore

/// The Drive photo metadata of one copy that the app shows: in the viewer's Info panel, on the map, and in the
/// timeline. Copies with the same bytes are duplicates only when their fingerprints are equal, so a merge never removes
/// information that the app shows. The file name does not count.
///
/// Every value is compared exactly, and a missing value never equals a present one. No tolerance applies: the
/// capture time is the server's whole Unix second, and the other values are the numbers and strings that the
/// uploader wrote into the revision's metadata, which decode to the same value for every read.
public struct ExactDuplicateFingerprint: Sendable, Hashable {
    public let captureTime: Date?
    public let latitude: Double?
    public let longitude: Double?
    /// The camera or device that took the photo.
    public let device: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// The length of a video in seconds.
    public let durationSeconds: Double?
    public let mimeType: String?
    /// Set for a node whose metadata cannot be compared, so its fingerprint matches no other node.
    private let onlyNode: PhotoUID?

    public init(
        captureTime: Date? = nil, latitude: Double? = nil, longitude: Double? = nil, device: String? = nil,
        pixelWidth: Int? = nil, pixelHeight: Int? = nil, durationSeconds: Double? = nil, mimeType: String? = nil
    ) {
        self.captureTime = captureTime
        self.latitude = latitude
        self.longitude = longitude
        self.device = device
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.mimeType = mimeType
        onlyNode = nil
    }

    private init(onlyNode: PhotoUID) {
        captureTime = nil
        latitude = nil
        longitude = nil
        device = nil
        pixelWidth = nil
        pixelHeight = nil
        durationSeconds = nil
        mimeType = nil
        self.onlyNode = onlyNode
    }

    /// A fingerprint that matches only the node `uid`: for a node without the photo metadata, such as a plain file
    /// without a capture time. Its copies are never offered as duplicates.
    public static func matchingOnly(_ uid: PhotoUID) -> ExactDuplicateFingerprint {
        ExactDuplicateFingerprint(onlyNode: uid)
    }

    /// The fingerprint of the metadata that the Info panel shows, with the capture time of the photo node.
    public init(captureTime: Date?, metadata: PhotoMetadata) {
        self.init(
            captureTime: captureTime, latitude: metadata.latitude, longitude: metadata.longitude,
            device: metadata.device, pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight,
            durationSeconds: metadata.durationSeconds, mimeType: metadata.mimeType)
    }

    /// A text that is equal for equal fingerprints and different for different ones.
    var key: String {
        func number(_ value: Double?) -> String { value.map { $0 == 0 ? "0" : "\($0)" } ?? "-" }
        func text(_ value: String?) -> String { value.map { "\($0.utf8.count):\($0)" } ?? "-" }
        return [
            number(captureTime?.timeIntervalSince1970), number(latitude), number(longitude), text(device),
            pixelWidth.map(String.init) ?? "-", pixelHeight.map(String.init) ?? "-", number(durationSeconds),
            text(mimeType), text(onlyNode.map { "\($0.volumeID)/\($0.nodeID)" }),
        ].joined(separator: ";")
    }
}

extension ExactDuplicateGroup {
    /// The groups of true duplicates among the members: members with equal fingerprints, two or more, in the order of
    /// `members`. A member without a fingerprint, or with a fingerprint that no other member has, is in no group.
    ///
    /// The part that holds `primary` keeps the ID of this group, so the screen keeps showing it in place; without such
    /// a part, the first part keeps it. Every other part gets an ID from its fingerprint. When that ID is this group's
    /// ID or one of `taken`, the IDs that the screen already shows, the part's first member makes it unique.
    public func split(
        by fingerprints: [PhotoUID: ExactDuplicateFingerprint], keepingIDWith primary: PhotoUID? = nil,
        avoiding taken: Set<String> = []
    ) -> [ExactDuplicateGroup] {
        var order: [ExactDuplicateFingerprint] = []
        var parts: [ExactDuplicateFingerprint: [PhotoUID]] = [:]
        for member in members {
            guard let fingerprint = fingerprints[member] else { continue }
            if parts[fingerprint] == nil { order.append(fingerprint) }
            parts[fingerprint, default: []].append(member)
        }
        let kept = order.filter { (parts[$0]?.count ?? 0) > 1 }
        let primaryPart =
            kept.first { fingerprint in primary.map { parts[fingerprint]?.contains($0) == true } ?? false }
            ?? kept.first
        return kept.map { fingerprint in
            let members = parts[fingerprint] ?? []
            return ExactDuplicateGroup(
                contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, members: members, fingerprint: fingerprint,
                id: fingerprint == primaryPart ? id : partID(fingerprint, first: members[0], avoiding: taken))
        }
    }

    private func partID(
        _ fingerprint: ExactDuplicateFingerprint, first: PhotoUID, avoiding taken: Set<String>
    ) -> String {
        let base = "\(contentHash)/\(fingerprint.key)"
        return base == id || taken.contains(base) ? "\(base)#\(first.nodeID)" : base
    }

    /// This group under another ID.
    func withID(_ id: String) -> ExactDuplicateGroup {
        ExactDuplicateGroup(
            contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, members: members, fingerprint: fingerprint, id: id)
    }

    /// This group with only `remaining` of its members, under the same ID and fingerprint.
    func keeping(_ remaining: [PhotoUID]) -> ExactDuplicateGroup {
        ExactDuplicateGroup(
            contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, members: members.filter(remaining.contains),
            fingerprint: fingerprint, id: id)
    }
}
