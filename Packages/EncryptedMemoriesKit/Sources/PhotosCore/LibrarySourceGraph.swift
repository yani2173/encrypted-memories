import Foundation

/// Stable, backend-opaque identity of one inventory source.
///
/// A source is not a storage volume. Multiple sources can expose the same `PhotoUID`, and one
/// volume can contain multiple sources. Backends own the mapping from this value to remote locators.
public struct SourceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Current access state for one source inventory.
public enum AccessState: String, Hashable, Sendable, Codable {
    /// The latest inventory completed and is authoritative.
    case available
    /// A refresh is running. The previous inventory remains readable but is not authoritative.
    case refreshing
    /// A refresh failed without proving access loss. The previous inventory remains readable.
    case temporarilyUnavailable
    /// The source is no longer accessible. Its memberships must not remain in any projection.
    case accessLost
}

/// Operations a backend can perform through one source.
///
/// Projection code selects an eligible source per operation. It never assumes that the source which
/// supplied preferred metadata can also supply bytes or accept a mutation.
public struct LibrarySourceCapabilities: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let readMetadata = Self(rawValue: 1 << 0)
    public static let readThumbnail = Self(rawValue: 1 << 1)
    public static let readContent = Self(rawValue: 1 << 2)
    public static let writeContent = Self(rawValue: 1 << 3)
    public static let observeChanges = Self(rawValue: 1 << 4)
    public static let removeSource = Self(rawValue: 1 << 5)

    /// Minimum route needed for an inventory to contribute useful media-derived work.
    ///
    /// Other routes stay independent. A source which can enumerate identities and read thumbnails may
    /// participate in analysis without claiming that metadata or original-content access also works.
    public static let requiredForInventory: Self = [.readThumbnail]
    public static let all: Self = [
        .readMetadata,
        .readThumbnail,
        .readContent,
        .writeContent,
        .observeChanges,
        .removeSource,
    ]
}

/// Stable description of one source. Runtime access state and inventory data live separately.
public struct LibrarySource: Hashable, Sendable, Codable {
    public let id: SourceID
    public let capabilities: LibrarySourceCapabilities
    /// Higher values win when two sources provide metadata for the same `PhotoUID`.
    public let precedence: Int
    /// Controls participation in the main projection. Exclusion does not revoke access or purge caches.
    public let isIncluded: Bool

    public init(
        id: SourceID,
        capabilities: LibrarySourceCapabilities,
        precedence: Int = 0,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.capabilities = capabilities
        self.precedence = precedence
        self.isIncluded = isIncluded
    }

    fileprivate func settingIncluded(_ included: Bool) -> Self {
        Self(id: id, capabilities: capabilities, precedence: precedence, isIncluded: included)
    }
}

/// Whether an inventory can drive destructive reconciliation of derived data.
public enum SourceInventoryAuthority: String, Hashable, Sendable, Codable {
    /// No complete inventory has been obtained in this process or restored from disk.
    case hydrating
    /// A previous complete inventory is available, but current remote completeness is unknown.
    case cached
    /// The inventory is a completed, current enumeration.
    case authoritative
}

/// Whether the host has finished discovering the complete configured source set.
public enum SourceSetAuthority: String, Hashable, Sendable, Codable {
    /// Discovery is incomplete. Derived-data consumers must not infer that absent sources were removed.
    case hydrating
    /// The current source set is complete. Individual inventories must still be authoritative.
    case authoritative
}

/// Metadata fields which one source has resolved conclusively for an item.
///
/// An absent field means unknown. It does not mean `false`, `nil`, or an empty collection. This distinction
/// lets a complete lower-precedence source fill a field without overriding known higher-precedence metadata.
public struct LibrarySourceMetadataFields: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let captureTime = Self(rawValue: 1 << 0)
    public static let mediaType = Self(rawValue: 1 << 1)
    public static let livePhotoRelationship = Self(rawValue: 1 << 2)
    public static let duration = Self(rawValue: 1 << 3)
    public static let tags = Self(rawValue: 1 << 4)
    public static let burstRelationship = Self(rawValue: 1 << 5)

    public static let requiredForProjection: Self = [.captureTime, .mediaType]
    public static let complete: Self = [
        .captureTime,
        .mediaType,
        .livePhotoRelationship,
        .duration,
        .tags,
        .burstRelationship,
    ]

    fileprivate static let individualFields: [Self] = [
        .captureTime,
        .mediaType,
        .livePhotoRelationship,
        .duration,
        .tags,
        .burstRelationship,
    ]
}

/// One source's metadata for a resource, including explicit field completeness.
public struct LibrarySourceItem: Hashable, Sendable, Codable {
    public let item: PhotoItem
    public let knownFields: LibrarySourceMetadataFields

    public var uid: PhotoUID { item.uid }

    public init(item: PhotoItem, knownFields: LibrarySourceMetadataFields) {
        self.knownFields = knownFields
        self.item = PhotoItem(
            uid: item.uid,
            captureTime: item.captureTime,
            mediaType: item.mediaType,
            isLivePhoto: knownFields.contains(.livePhotoRelationship) ? item.isLivePhoto : false,
            relatedVideoID: knownFields.contains(.livePhotoRelationship) ? item.relatedVideoID : nil,
            durationSeconds: knownFields.contains(.duration) ? item.durationSeconds : nil,
            tags: knownFields.contains(.tags) ? item.tags : [],
            burstMemberIDs: knownFields.contains(.burstRelationship) ? item.burstMemberIDs : [],
            timelineOrder: item.timelineOrder
        )
    }

    public static func complete(_ item: PhotoItem) -> Self {
        Self(item: item, knownFields: .complete)
    }

    private enum CodingKeys: String, CodingKey {
        case item
        case knownFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            item: try container.decode(PhotoItem.self, forKey: .item),
            knownFields: try container.decode(LibrarySourceMetadataFields.self, forKey: .knownFields)
        )
    }
}

/// Persistable state for one source inventory.
///
/// Restoring this value never restores runtime authority. `LibrarySourceGraph` downgrades accessible
/// inventories to cached or hydrating state until a current enumeration completes.
public struct LibrarySourceInventory: Sendable, Codable {
    public let source: LibrarySource
    public let accessState: AccessState
    public let authority: SourceInventoryAuthority
    public let items: [LibrarySourceItem]
    public let validationToken: String?

    public init(
        source: LibrarySource,
        accessState: AccessState,
        authority: SourceInventoryAuthority,
        items: [LibrarySourceItem],
        validationToken: String? = nil
    ) {
        self.source = source
        self.accessState = accessState
        self.authority = authority
        self.items = items
        self.validationToken = validationToken
    }
}

public enum LibrarySourceInventoryValidationError: Error, Sendable, Equatable {
    case duplicateSourceID(SourceID)
    case invalidSourceID(SourceID)
    case invalidCapabilities(SourceID)
    case invalidState(SourceID)
    case duplicateItemUID(sourceID: SourceID, uid: PhotoUID)
    case invalidItemFields(sourceID: SourceID, uid: PhotoUID)
}

enum LibrarySourceInventoryValidator {
    static func hasValidDescriptor(_ source: LibrarySource) -> Bool {
        !source.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && source.capabilities.subtracting(.all).isEmpty
    }

    static func isAdmitted(_ source: LibrarySource) -> Bool {
        hasValidDescriptor(source)
            && source.capabilities.contains(.requiredForInventory)
    }

    static func hasValidItem(_ sourceItem: LibrarySourceItem) -> Bool {
        let item = sourceItem.item
        let validDuration = item.durationSeconds.map { $0.isFinite && $0 >= 0 } ?? true
        let validRelatedVideo =
            item.relatedVideoID.map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? true
        let coherentLivePhotoRelationship =
            !sourceItem.knownFields.contains(.livePhotoRelationship)
            || (item.isLivePhoto
                ? item.relatedVideoID != nil && item.relatedVideoID != item.uid.nodeID
                : item.relatedVideoID == nil)
        let validBurstMembers =
            item.burstMemberIDs.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } && Set(item.burstMemberIDs).count == item.burstMemberIDs.count
        let validCaptureTime =
            !sourceItem.knownFields.contains(.captureTime)
            || item.captureTime.timeIntervalSinceReferenceDate.isFinite
        let validMediaType =
            !sourceItem.knownFields.contains(.mediaType)
            || !item.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validKnownDuration = !sourceItem.knownFields.contains(.duration) || validDuration
        let validKnownLiveRelationship =
            !sourceItem.knownFields.contains(.livePhotoRelationship)
            || (validRelatedVideo && coherentLivePhotoRelationship)
        let validKnownBurstRelationship =
            !sourceItem.knownFields.contains(.burstRelationship) || validBurstMembers
        return sourceItem.knownFields.subtracting(.complete).isEmpty
            && !item.uid.volumeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !item.uid.nodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validCaptureTime
            && validMediaType
            && validKnownDuration
            && validKnownLiveRelationship
            && validKnownBurstRelationship
    }

    static func validate(_ inventories: [LibrarySourceInventory]) throws {
        var seenSources = Set<SourceID>()
        for inventory in inventories {
            let sourceID = inventory.source.id
            guard seenSources.insert(sourceID).inserted else {
                throw LibrarySourceInventoryValidationError.duplicateSourceID(sourceID)
            }
            guard !sourceID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibrarySourceInventoryValidationError.invalidSourceID(sourceID)
            }
            guard isAdmitted(inventory.source) else {
                throw LibrarySourceInventoryValidationError.invalidCapabilities(sourceID)
            }

            switch (inventory.accessState, inventory.authority) {
            case (.available, .authoritative),
                (.refreshing, .hydrating),
                (.refreshing, .cached),
                (.temporarilyUnavailable, .hydrating),
                (.temporarilyUnavailable, .cached):
                break
            case (.accessLost, .authoritative)
            where inventory.items.isEmpty && inventory.validationToken == nil:
                break
            default:
                throw LibrarySourceInventoryValidationError.invalidState(sourceID)
            }

            var seenItems = Set<PhotoUID>()
            for item in inventory.items {
                guard seenItems.insert(item.uid).inserted else {
                    throw LibrarySourceInventoryValidationError.duplicateItemUID(
                        sourceID: sourceID,
                        uid: item.uid
                    )
                }
                guard hasValidItem(item) else {
                    throw LibrarySourceInventoryValidationError.invalidItemFields(
                        sourceID: sourceID,
                        uid: item.uid
                    )
                }
            }
        }
    }
}

/// Generation lease for one source refresh. A commit with a stale lease is rejected.
public struct SourceUpdateLease: Hashable, Sendable {
    public let sourceID: SourceID
    fileprivate let epoch: LibrarySourceEpoch
    fileprivate let generation: UInt64
}

/// Generation lease for one complete source-set discovery.
public struct SourceSetUpdateLease: Hashable, Sendable {
    fileprivate let epoch: LibrarySourceEpoch
    fileprivate let generation: UInt64
    fileprivate let previousAuthority: SourceSetAuthority
}

/// Capability-bound access lease for one resource route.
///
/// Access loss, membership removal, reactivation after access loss, and every inventory refresh that changes an
/// item invalidate it. `renewed(_:)` issues the same route again when the graph still authorizes it. A changed
/// backend route must use a new `SourceID`.
public struct SourceAccessLease: Hashable, Sendable {
    public let sourceID: SourceID
    public let uid: PhotoUID
    public let capability: LibrarySourceCapabilities
    fileprivate let epoch: LibrarySourceEpoch
    fileprivate let generation: UInt64
    fileprivate let requiresInclusion: Bool
    fileprivate let membershipUID: PhotoUID
    fileprivate let relationship: LibrarySourceRelationship?
    /// True for an identity the user addresses outside every source inventory, such as a photo in the
    /// volume trash. The source proves access; no inventory membership exists to prove.
    fileprivate var readsIdentityOutsideInventory: Bool = false
}

/// A relationship whose target bytes are addressed separately from the owning timeline item.
public enum LibrarySourceRelationship: Hashable, Sendable {
    case livePhotoMotion
    case burstMember

    fileprivate var metadataField: LibrarySourceMetadataFields {
        switch self {
        case .livePhotoMotion: .livePhotoRelationship
        case .burstMember: .burstRelationship
        }
    }
}

/// Opaque runtime identity for one graph lifetime.
///
/// A new or restored graph gets a new epoch, so generations and scope revisions cannot collide across
/// account/session replacement. Only the graph and package consumers can create this value.
public struct LibrarySourceEpoch: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
        rawValue = UUID()
    }
}

/// Compile-time marker for one derived-data retention policy.
public protocol DerivedDataScopeKind: Sendable {}

public enum SelectedDerivedDataScopeKind: DerivedDataScopeKind {}
public enum AnalysisDerivedDataScopeKind: DerivedDataScopeKind {}
public enum RetentionDerivedDataScopeKind: DerivedDataScopeKind {}
public enum ThumbnailRetentionDerivedDataScopeKind: DerivedDataScopeKind {}
public enum VideoRetentionDerivedDataScopeKind: DerivedDataScopeKind {}

/// One consumer-specific, deduplicated derived-data inventory.
///
/// The phantom `Kind` prevents a selected-view scope from reaching a global cache purge API.
public struct DerivedDataScope<Kind: DerivedDataScopeKind>: Sendable, Equatable {
    public let epoch: LibrarySourceEpoch
    public let sourceIDs: Set<SourceID>
    /// Stable timeline order for deterministic indexing and crawl scheduling.
    public let orderedUIDs: [PhotoUID]
    public let uids: Set<PhotoUID>
    /// Identities the consumer may read although no inventory lists them: the volume trash listing. They stay
    /// out of `orderedUIDs`, so no analysis or relationship consumer treats them as library photos.
    public let authorizationOnlyUIDs: Set<PhotoUID>
    /// The same identities, newest first. The thumbnail crawl fetches them after every library photo.
    public let authorizationOnlyOrder: [PhotoUID]
    public let isAuthoritative: Bool
    public let revision: UInt64

    fileprivate init(
        epoch: LibrarySourceEpoch = LibrarySourceEpoch(),
        sourceIDs: Set<SourceID>,
        orderedUIDs: [PhotoUID],
        authorizationOnlyUIDs: [PhotoUID] = [],
        isAuthoritative: Bool,
        revision: UInt64
    ) {
        self.epoch = epoch
        self.sourceIDs = sourceIDs
        var seen = Set<PhotoUID>()
        self.orderedUIDs = orderedUIDs.filter { seen.insert($0).inserted }
        let listed = seen
        self.authorizationOnlyOrder = authorizationOnlyUIDs.filter { !listed.contains($0) && seen.insert($0).inserted }
        self.authorizationOnlyUIDs = Set(self.authorizationOnlyOrder)
        self.uids = seen
        self.isAuthoritative = isAuthoritative
        self.revision = revision
    }

    public func delta(from previous: Self) -> DerivedDataScopeDelta<Kind> {
        guard epoch == previous.epoch, revision >= previous.revision else {
            return DerivedDataScopeDelta<Kind>(
                addedUIDs: [],
                removedUIDs: [],
                allowsDestructiveReconciliation: false
            )
        }
        let allowsDestructiveReconciliation = isAuthoritative
        return DerivedDataScopeDelta<Kind>(
            addedUIDs: uids.subtracting(previous.uids),
            removedUIDs: allowsDestructiveReconciliation
                ? previous.uids.subtracting(uids) : [],
            allowsDestructiveReconciliation: allowsDestructiveReconciliation
        )
    }
}

public typealias SelectedDerivedDataScope = DerivedDataScope<SelectedDerivedDataScopeKind>
public typealias AnalysisDerivedDataScope = DerivedDataScope<AnalysisDerivedDataScopeKind>
public typealias RetentionDerivedDataScope = DerivedDataScope<RetentionDerivedDataScopeKind>
public typealias ThumbnailRetentionDerivedDataScope =
    DerivedDataScope<ThumbnailRetentionDerivedDataScopeKind>
public typealias VideoRetentionDerivedDataScope =
    DerivedDataScope<VideoRetentionDerivedDataScopeKind>

public struct DerivedDataScopeDelta<Kind: DerivedDataScopeKind>: Sendable, Equatable {
    public let addedUIDs: Set<PhotoUID>
    public let removedUIDs: Set<PhotoUID>
    /// False means consumers may add work but must retain existing derived data.
    public let allowsDestructiveReconciliation: Bool
}

public enum DerivedDataScopeFenceDecision: Sendable, Equatable {
    case accepted
    case unbound
    case epochMismatch
    case staleRevision
}

/// Synchronous revision fence for stateful derived-data consumers.
///
/// The fence holds its lock across the consumer mutation. A newer scope cannot commit first and then be
/// overwritten by an older asynchronous caller. Failed mutations do not consume their revision and can retry.
public final class DerivedDataScopeRevisionFence<Kind: DerivedDataScopeKind>: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: LibrarySourceEpoch?
    private var highestAcceptedRevision: UInt64?
    private var lastCommittedScope: DerivedDataScope<Kind>?

    package init() {}

    /// Binds an unbound fence. Rebinding the same epoch is idempotent and never resets its revision.
    /// A different epoch requires a new owning consumer instance.
    package func bindIfNeeded(to epoch: LibrarySourceEpoch) -> Bool {
        bindIfNeeded(to: epoch, validating: { true })
    }

    /// Binds only while the caller's owning session lease is current. The validator runs under the fence,
    /// so a concurrent session reset cannot leave a delayed old epoch installed afterwards.
    package func bindIfNeeded(
        to epoch: LibrarySourceEpoch,
        validating isCurrentSession: () -> Bool
    ) -> Bool {
        lock.withLock {
            guard isCurrentSession() else { return false }
            guard self.epoch == nil else { return self.epoch == epoch }
            self.epoch = epoch
            return true
        }
    }

    /// Atomically resets epoch and revision state around an owning session transition.
    package func resetForSessionTransition(_ transition: () -> Void) {
        lock.withLock {
            transition()
            epoch = nil
            highestAcceptedRevision = nil
            lastCommittedScope = nil
        }
    }

    package func perform<Value>(
        with scope: DerivedDataScope<Kind>,
        _ operation: (_ previousScope: DerivedDataScope<Kind>?) -> (
            value: Value,
            commitsRevision: Bool
        )
    ) -> (decision: DerivedDataScopeFenceDecision, value: Value?) {
        lock.lock()
        defer { lock.unlock() }
        guard let epoch else { return (.unbound, nil) }
        guard epoch == scope.epoch else { return (.epochMismatch, nil) }
        if let highestAcceptedRevision {
            guard scope.revision >= highestAcceptedRevision else {
                return (.staleRevision, nil)
            }
        }
        if let lastCommittedScope {
            guard scope == lastCommittedScope || scope.revision > lastCommittedScope.revision else {
                return (.staleRevision, nil)
            }
        }
        if highestAcceptedRevision.map({ scope.revision > $0 }) ?? true {
            highestAcceptedRevision = scope.revision
        }
        let result = operation(lastCommittedScope)
        if result.commitsRevision {
            lastCommittedScope = scope
        }
        return (.accepted, result.value)
    }
}

/// Thread-safe allow-list installed from an accepted source scope.
/// Legacy consumers stay unrestricted until they explicitly bind to a source graph.
public final class DerivedDataResourceAuthorization<Kind: DerivedDataScopeKind>: @unchecked Sendable {
    private let lock = NSLock()
    private var allowedUIDs: Set<PhotoUID>?

    package init() {}

    package func apply(_ scope: DerivedDataScope<Kind>) {
        lock.withLock { allowedUIDs = scope.uids }
    }

    /// Makes an explicitly source-aware consumer fail closed until its first accepted scope arrives.
    package func requireScope() {
        lock.withLock {
            if allowedUIDs == nil { allowedUIDs = [] }
        }
    }

    package func isAllowed(_ uid: PhotoUID) -> Bool {
        lock.withLock { allowedUIDs?.contains(uid) ?? true }
    }

    package func reset() {
        lock.withLock { allowedUIDs = nil }
    }
}

/// A deduplicated timeline plus the source memberships used for capability routing.
public struct LibrarySourceProjection: Sendable {
    public let timeline: TimelineContentProjection
    private let metadataByUID: [PhotoUID: LibrarySourceItem]
    private let membershipsByUID: [PhotoUID: Set<SourceID>]
    private let sourcesByID: [SourceID: LibrarySource]
    private let metadataProvenanceByUID: [PhotoUID: [LibrarySourceMetadataFields: SourceID]]

    fileprivate init(
        timeline: TimelineContentProjection,
        metadataByUID: [PhotoUID: LibrarySourceItem],
        membershipsByUID: [PhotoUID: Set<SourceID>],
        sourcesByID: [SourceID: LibrarySource],
        metadataProvenanceByUID: [PhotoUID: [LibrarySourceMetadataFields: SourceID]]
    ) {
        self.timeline = timeline
        self.metadataByUID = metadataByUID
        self.membershipsByUID = membershipsByUID
        self.sourcesByID = sourcesByID
        self.metadataProvenanceByUID = metadataProvenanceByUID
    }

    public func sourceIDs(for uid: PhotoUID) -> Set<SourceID> {
        membershipsByUID[uid] ?? []
    }

    public func metadata(for uid: PhotoUID) -> LibrarySourceItem? {
        metadataByUID[uid]
    }

    /// Source which supplied one resolved metadata field after precedence merging.
    public func sourceID(
        for uid: PhotoUID,
        metadataField: LibrarySourceMetadataFields
    ) -> SourceID? {
        guard LibrarySourceMetadataFields.individualFields.contains(metadataField) else { return nil }
        return metadataProvenanceByUID[uid]?[metadataField]
    }

    public func capabilities(for uid: PhotoUID) -> LibrarySourceCapabilities {
        sourceIDs(for: uid).reduce(into: LibrarySourceCapabilities()) { capabilities, sourceID in
            if let source = sourcesByID[sourceID] {
                capabilities.formUnion(source.capabilities)
            }
        }
    }

    /// Highest-precedence source which can perform `capability`, with source ID as a stable tie-breaker.
    public func preferredSourceID(
        for uid: PhotoUID,
        requiring capability: LibrarySourceCapabilities
    ) -> SourceID? {
        sourceIDs(for: uid)
            .compactMap { sourcesByID[$0] }
            .filter { $0.capabilities.contains(capability) }
            .sorted(by: Self.sourcePrecedes)
            .first?.id
    }

    fileprivate static func sourcePrecedes(_ lhs: LibrarySource, _ rhs: LibrarySource) -> Bool {
        if lhs.precedence != rhs.precedence { return lhs.precedence > rhs.precedence }
        return lhs.id.rawValue.utf8.lexicographicallyPrecedes(rhs.id.rawValue.utf8)
    }
}

/// Atomic result of one accepted graph mutation.
public struct LibrarySourceChange: Sendable {
    public let selectedProjection: LibrarySourceProjection
    public let retentionProjection: LibrarySourceProjection
    public let selectedScope: SelectedDerivedDataScope
    /// Every accessible identity whose source can supply a thumbnail, independent of main-view inclusion.
    public let analysisScope: AnalysisDerivedDataScope
    /// Primary projected items. This scope must not drive deletion of separately addressed resources.
    public let retentionScope: RetentionDerivedDataScope
    /// Primary items plus every burst member proven by any accessible source membership.
    public let thumbnailRetentionScope: ThumbnailRetentionDerivedDataScope
    /// Primary items plus every motion resource proven by any accessible source membership.
    public let videoRetentionScope: VideoRetentionDerivedDataScope
    /// Resources proven to have lost their final accessible source membership in this mutation.
    ///
    /// This set stays empty while the retention scope is non-authoritative. Consumers then keep existing
    /// data and run full reconciliation when a later authoritative retention scope arrives.
    public let orphanedUIDs: Set<PhotoUID>
}

/// Typed retention baseline for one coordinator-owned batch of graph mutations.
/// It lets the graph build one final consumer projection without losing last-reference removals.
package struct LibrarySourceChangeBaseline: Sendable {
    fileprivate let epoch: LibrarySourceEpoch
    fileprivate let retentionUIDs: Set<PhotoUID>
}

/// Exact in-process identity of the graph fields persisted by the source inventory store.
/// Item generations change whenever item payloads change, so equality never requires rescanning them.
package struct LibrarySourcePersistenceSignature: Equatable, Sendable {
    fileprivate struct Entry: Equatable, Sendable {
        let sourceID: SourceID
        let capabilities: LibrarySourceCapabilities
        let precedence: Int
        let accessState: AccessState
        let authority: SourceInventoryAuthority
        let validationToken: String?
        let itemGeneration: UInt64
    }

    fileprivate let sourceSetAuthority: SourceSetAuthority
    fileprivate let entries: [Entry]
    fileprivate let additionalStateGeneration: UInt64
}

/// Universal source-membership reducer.
///
/// Hosts keep backend locators outside this type. The graph owns refresh generations, cached-state
/// retention, access-loss fencing, projection deduplication, and derived-data authority.
///
/// This non-Sendable reference type cannot diverge through value copies. A host actor or coordinator owns
/// one instance and publishes its Sendable projections, leases, and scopes to asynchronous consumers.
public final class LibrarySourceGraph {
    private struct Record: Sendable {
        var source: LibrarySource
        var accessState: AccessState
        var authority: SourceInventoryAuthority
        var items: [LibrarySourceItem]
        /// Constant-time membership and relationship lookup without duplicating item payloads.
        var itemIndexByUID: [PhotoUID: Int]
        /// Items that list each burst member, so a filmstrip or crawl lease needs no inventory scan.
        var burstOwnersByMemberUID: [PhotoUID: [PhotoUID]]
        var validationToken: String?
        var refreshGeneration: UInt64
        var accessGeneration: UInt64
        /// Changes only when the persisted item payload changes. Transient refresh-state changes do
        /// not force a complete item comparison in the persistence layer after a no-op refresh.
        var itemGeneration: UInt64
    }

    private var records: [SourceID: Record] = [:]
    /// Identities the user addresses although no source inventory lists them: the volume trash listing.
    /// They authorize thumbnail reads and join the thumbnail crawl last; no other crawl order contains them.
    private var identitiesOutsideInventory: Set<PhotoUID> = []
    /// The same identities, newest first, for the thumbnail crawl.
    private var identitiesOutsideInventoryOrder: [PhotoUID] = []
    private let epoch = LibrarySourceEpoch()
    private var sourceSetGeneration: UInt64 = 0
    public private(set) var sourceSetAuthority: SourceSetAuthority
    public private(set) var revision: UInt64 = 0

    public var runtimeEpoch: LibrarySourceEpoch { epoch }

    public init() {
        self.sourceSetAuthority = .hydrating
    }

    /// Restores cached inventories without restoring source-set or inventory authority.
    /// Only a current `commitSourceSet` call can authorize an empty or reduced global scope.
    public init(restoring inventories: [LibrarySourceInventory]) throws {
        try LibrarySourceInventoryValidator.validate(inventories)
        self.sourceSetAuthority = .hydrating
        for inventory in inventories {
            let items =
                inventory.accessState == .accessLost
                ? [] : Self.canonicalItems(inventory.items)
            let restoredAccessState: AccessState =
                inventory.accessState == .accessLost ? .accessLost : .temporarilyUnavailable
            let restoredAuthority: SourceInventoryAuthority =
                inventory.accessState == .accessLost ? .authoritative : (items.isEmpty ? .hydrating : .cached)
            records[inventory.source.id] = Record(
                source: inventory.source,
                accessState: restoredAccessState,
                authority: restoredAuthority,
                items: items,
                itemIndexByUID: Self.itemIndexByUID(items),
                burstOwnersByMemberUID: Self.burstOwnersByMemberUID(items),
                validationToken: inventory.accessState == .accessLost ? nil : inventory.validationToken,
                refreshGeneration: 0,
                accessGeneration: 0,
                itemGeneration: 0
            )
        }
    }

    /// Starts discovery of the complete configured source set. Existing inventories stay readable, but
    /// destructive derived-data reconciliation pauses until this lease commits.
    @discardableResult
    public func beginSourceSetRefresh() -> SourceSetUpdateLease {
        let previousAuthority = sourceSetAuthority
        sourceSetGeneration &+= 1
        sourceSetAuthority = .hydrating
        revision &+= 1
        return SourceSetUpdateLease(
            epoch: epoch,
            generation: sourceSetGeneration,
            previousAuthority: previousAuthority
        )
    }

    /// Ends a failed discovery without turning a previously complete source set into permanent hydration.
    /// A first-launch failure remains hydrating because no complete source set has been observed yet.
    public func failSourceSetRefresh(using lease: SourceSetUpdateLease) -> LibrarySourceChange? {
        guard lease.epoch == epoch, lease.generation == sourceSetGeneration else { return nil }
        sourceSetGeneration &+= 1
        sourceSetAuthority = lease.previousAuthority
        revision &+= 1
        return makeChange(previousRetentionUIDs: retentionUIDs())
    }

    /// Commits the complete configured source set.
    ///
    /// Sources absent from an authoritative replacement become access-lost tombstones. New and reactivated
    /// sources start without inventory authority and require an individual refresh.
    public func commitSourceSet(
        _ sources: [LibrarySource],
        using lease: SourceSetUpdateLease
    ) -> LibrarySourceChange? {
        let previousRetentionUIDs = retentionUIDs()
        guard applySourceSet(sources, using: lease) else { return nil }
        return makeChange(previousRetentionUIDs: previousRetentionUIDs)
    }

    /// Applies an accepted source-set replacement without building consumer projections.
    /// A coordinator captures one change baseline and publishes one final snapshot after its batch.
    @discardableResult
    package func commitSourceSetWithoutProjection(
        _ sources: [LibrarySource],
        using lease: SourceSetUpdateLease
    ) -> Bool {
        applySourceSet(sources, using: lease)
    }

    private func applySourceSet(
        _ sources: [LibrarySource],
        using lease: SourceSetUpdateLease
    ) -> Bool {
        guard lease.epoch == epoch, lease.generation == sourceSetGeneration else { return false }
        let sourceIDs = sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count,
            sources.allSatisfy(LibrarySourceInventoryValidator.isAdmitted)
        else { return false }

        // Reject an invalid descriptor set as one atomic unit. Silently filtering a source here could
        // turn a transient capability-discovery failure into an authoritative global deletion.
        let incoming = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })

        for sourceID in Array(records.keys) where incoming[sourceID] == nil {
            guard var record = records[sourceID], record.accessState != .accessLost else { continue }
            record.refreshGeneration &+= 1
            record.accessGeneration &+= 1
            if !record.items.isEmpty { record.itemGeneration &+= 1 }
            record.accessState = .accessLost
            record.authority = .authoritative
            record.items = []
            record.itemIndexByUID = [:]
            record.burstOwnersByMemberUID = [:]
            record.validationToken = nil
            records[sourceID] = record
        }

        for source in sources {
            if var record = records[source.id] {
                // Source discovery must not overwrite a concurrent local projection preference.
                let discoveredSource = source.settingIncluded(record.source.isIncluded)
                let reactivating = record.accessState == .accessLost
                if reactivating {
                    record.refreshGeneration &+= 1
                    record.accessGeneration &+= 1
                    if !record.items.isEmpty { record.itemGeneration &+= 1 }
                    record.accessState = .temporarilyUnavailable
                    record.authority = .hydrating
                    record.items = []
                    record.itemIndexByUID = [:]
                    record.burstOwnersByMemberUID = [:]
                    record.validationToken = nil
                }
                if !reactivating, record.source.capabilities != discoveredSource.capabilities {
                    record.accessGeneration &+= 1
                }
                record.source = discoveredSource
                records[source.id] = record
            } else {
                records[source.id] = Record(
                    source: source,
                    accessState: .temporarilyUnavailable,
                    authority: .hydrating,
                    items: [],
                    itemIndexByUID: [:],
                    burstOwnersByMemberUID: [:],
                    validationToken: nil,
                    refreshGeneration: 0,
                    accessGeneration: 1,
                    itemGeneration: 0
                )
            }
        }

        // Consume the accepted discovery lease. Replaying it after later mutations must not revoke sources.
        sourceSetGeneration &+= 1
        sourceSetAuthority = .authoritative
        revision &+= 1
        return true
    }

    /// Retains the previous inventory while a new authoritative enumeration runs.
    public func beginRefresh(_ sourceID: SourceID) -> SourceUpdateLease? {
        guard var record = records[sourceID], record.accessState != .accessLost else { return nil }
        record.refreshGeneration &+= 1
        record.accessState = .refreshing
        record.authority = record.items.isEmpty ? .hydrating : .cached
        records[sourceID] = record
        revision &+= 1
        return SourceUpdateLease(
            sourceID: sourceID,
            epoch: epoch,
            generation: record.refreshGeneration
        )
    }

    /// Commits one complete membership enumeration with explicit per-field metadata completeness.
    ///
    /// Items may contain only identity plus fields the backend proved. Projection consumers require
    /// their own fields; thumbnail analysis can use a partial item without an N+1 metadata crawl.
    public func commit(
        _ items: [LibrarySourceItem],
        validationToken: String?,
        using lease: SourceUpdateLease
    ) -> LibrarySourceChange? {
        let previousRetentionUIDs = retentionUIDs()
        guard applyRefreshItems(items, validationToken: validationToken, using: lease) else {
            return nil
        }
        return makeChange(previousRetentionUIDs: previousRetentionUIDs)
    }

    private func applyRefreshItems(
        _ items: [LibrarySourceItem],
        validationToken: String?,
        using lease: SourceUpdateLease
    ) -> Bool {
        guard lease.epoch == epoch, var record = records[lease.sourceID],
            record.refreshGeneration == lease.generation,
            record.accessState != .accessLost,
            Self.isValidEnumeration(items)
        else { return false }
        let canonicalItems = Self.canonicalItems(
            items,
            preservingKnownFieldsFrom: record.items
        )
        if record.items != canonicalItems {
            // Invalidate every route lease when membership or relationship metadata changes. This also
            // closes remove-then-readd ABA races for separately addressed relationship resources.
            record.accessGeneration &+= 1
            record.itemGeneration &+= 1
        }
        record.refreshGeneration &+= 1
        record.items = canonicalItems
        record.itemIndexByUID = Self.itemIndexByUID(canonicalItems)
        record.burstOwnersByMemberUID = Self.burstOwnersByMemberUID(canonicalItems)
        record.validationToken = validationToken
        record.accessState = .available
        record.authority = .authoritative
        records[lease.sourceID] = record
        revision &+= 1
        return true
    }

    /// Installs a locally persisted inventory without claiming current remote completeness.
    /// A cached frame can add query-visible work, but it cannot authorize destructive reconciliation.
    /// Valid unchanged input returns the current snapshot without advancing its revision; `nil` means rejection.
    public func installCachedInventory(
        _ items: [LibrarySourceItem],
        validationToken: String? = nil,
        for sourceID: SourceID
    ) -> LibrarySourceChange? {
        guard var record = records[sourceID],
            record.accessState != .accessLost,
            record.authority != .authoritative,
            Self.isValidEnumeration(items)
        else { return nil }
        let previousRetentionUIDs = retentionUIDs()
        let canonicalItems = Self.canonicalItems(
            items,
            preservingKnownFieldsFrom: record.items
        )
        let nextAuthority: SourceInventoryAuthority = canonicalItems.isEmpty ? .hydrating : .cached
        guard
            record.items != canonicalItems
                || record.authority != nextAuthority
                || record.accessState != .temporarilyUnavailable
                || record.validationToken != validationToken
        else { return snapshot() }
        if record.items != canonicalItems {
            record.accessGeneration &+= 1
            record.itemGeneration &+= 1
        }
        record.refreshGeneration &+= 1
        record.items = canonicalItems
        record.itemIndexByUID = Self.itemIndexByUID(canonicalItems)
        record.burstOwnersByMemberUID = Self.burstOwnersByMemberUID(canonicalItems)
        record.validationToken = validationToken
        record.accessState = .temporarilyUnavailable
        record.authority = nextAuthority
        records[sourceID] = record
        revision &+= 1
        return makeChange(previousRetentionUIDs: previousRetentionUIDs)
    }

    /// Marks a non-terminal refresh failure and keeps the last complete inventory.
    public func failRefresh(using lease: SourceUpdateLease) -> LibrarySourceChange? {
        let previousRetentionUIDs = retentionUIDs()
        guard applyRefreshFailure(using: lease) else { return nil }
        return makeChange(previousRetentionUIDs: previousRetentionUIDs)
    }

    private func applyRefreshFailure(using lease: SourceUpdateLease) -> Bool {
        guard lease.epoch == epoch, var record = records[lease.sourceID],
            record.refreshGeneration == lease.generation,
            record.accessState != .accessLost
        else { return false }
        record.refreshGeneration &+= 1
        record.accessState = .temporarilyUnavailable
        record.authority = record.items.isEmpty ? .hydrating : .cached
        records[lease.sourceID] = record
        revision &+= 1
        return true
    }

    /// Finishes one source refresh without materializing a projection. Invalid or unavailable results
    /// retain the last complete inventory with non-authoritative state, matching the public methods.
    @discardableResult
    package func finishRefreshWithoutProjection(
        _ items: [LibrarySourceItem]?,
        validationToken: String?,
        using lease: SourceUpdateLease
    ) -> Bool {
        if let items,
            applyRefreshItems(items, validationToken: validationToken, using: lease)
        {
            return true
        }
        return applyRefreshFailure(using: lease)
    }

    /// Revokes a source, drops every membership, and invalidates all outstanding refresh leases.
    public func removeSource(_ sourceID: SourceID) -> LibrarySourceChange? {
        guard var record = records[sourceID], record.accessState != .accessLost else { return nil }
        let previousRetentionUIDs = retentionUIDs()
        // A catalog result captured before terminal access loss must not reactivate the source.
        sourceSetGeneration &+= 1
        record.refreshGeneration &+= 1
        record.accessGeneration &+= 1
        if !record.items.isEmpty { record.itemGeneration &+= 1 }
        record.accessState = .accessLost
        record.authority = .authoritative
        record.items = []
        record.itemIndexByUID = [:]
        record.burstOwnersByMemberUID = [:]
        record.validationToken = nil
        records[sourceID] = record
        revision &+= 1
        return makeChange(previousRetentionUIDs: previousRetentionUIDs)
    }

    /// Registers the identities of a route that reads outside every inventory, currently Recently Deleted,
    /// newest first.
    ///
    /// A trashed photo is still the user's own photo on an accessible source, but it left the inventory, so
    /// neither a scope nor a lease could authorize its thumbnail and every tile stayed black. The list
    /// authorizes thumbnail reads and keeps their bytes while the photo stays in the trash; the thumbnail crawl
    /// fetches them after every library photo. A later list without a photo releases its bytes again.
    public func setIdentitiesOutsideInventory(_ uids: [PhotoUID]) -> LibrarySourceChange? {
        var seen = Set<PhotoUID>()
        let ordered = uids.filter { seen.insert($0).inserted }
        guard identitiesOutsideInventoryOrder != ordered else { return nil }
        let previousRetentionUIDs = retentionUIDs()
        identitiesOutsideInventory = seen
        identitiesOutsideInventoryOrder = ordered
        revision &+= 1
        return makeChange(previousRetentionUIDs: previousRetentionUIDs)
    }

    /// Leases for identities registered through `setIdentitiesOutsideInventory`. The lease proves source
    /// access, not inventory membership, so it stays valid while that route shows the photo.
    public func identityOutsideInventoryAccessLeases(
        for uids: Set<PhotoUID>,
        requiring capability: LibrarySourceCapabilities,
        includeExcludedSources: Bool = true
    ) -> [PhotoUID: SourceAccessLease] {
        let requested = uids.intersection(identitiesOutsideInventory)
        guard !requested.isEmpty, !capability.isEmpty, capability.subtracting(.all).isEmpty else { return [:] }
        var selectedID: SourceID?
        for (sourceID, record) in records
        where record.accessState != .accessLost
            && (includeExcludedSources || record.source.isIncluded)
            && record.source.capabilities.contains(capability)
        {
            if let selectedID, let selected = records[selectedID],
                !LibrarySourceProjection.sourcePrecedes(record.source, selected.source)
            {
                continue
            }
            selectedID = sourceID
        }
        guard let selectedID, let record = records[selectedID] else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: requested.map { uid in
                (
                    uid,
                    SourceAccessLease(
                        sourceID: selectedID,
                        uid: uid,
                        capability: capability,
                        epoch: epoch,
                        generation: record.accessGeneration,
                        requiresInclusion: !includeExcludedSources,
                        membershipUID: uid,
                        relationship: nil,
                        readsIdentityOutsideInventory: true
                    )
                )
            })
    }

    /// Changes main-projection participation without changing access or retention reachability.
    public func setIncluded(_ included: Bool, for sourceID: SourceID) -> LibrarySourceChange? {
        guard var record = records[sourceID], record.source.isIncluded != included else { return nil }
        let previousRetentionUIDs = retentionUIDs()
        record.accessGeneration &+= 1
        record.source = record.source.settingIncluded(included)
        records[sourceID] = record
        revision &+= 1
        return makeChange(previousRetentionUIDs: previousRetentionUIDs)
    }

    public func inventory(for sourceID: SourceID) -> LibrarySourceInventory? {
        guard let record = records[sourceID] else { return nil }
        return LibrarySourceInventory(
            source: record.source,
            accessState: record.accessState,
            authority: record.authority,
            items: record.items,
            validationToken: record.validationToken
        )
    }

    public func inventories() -> [LibrarySourceInventory] {
        records.keys.sorted(by: Self.sourceIDPrecedes).compactMap(inventory(for:))
    }

    /// Returns a compact identity for the exact persisted graph state. The coordinator adds its
    /// own overlay generation for persisted state which intentionally lives outside this graph.
    package func persistenceSignature(
        excluding excludedSourceIDs: Set<SourceID> = [],
        additionalStateGeneration: UInt64
    ) -> LibrarySourcePersistenceSignature {
        let entries = records.keys.sorted(by: Self.sourceIDPrecedes).compactMap {
            sourceID -> LibrarySourcePersistenceSignature.Entry? in
            guard !excludedSourceIDs.contains(sourceID) else { return nil }
            guard let record = records[sourceID] else { return nil }
            return LibrarySourcePersistenceSignature.Entry(
                sourceID: sourceID,
                capabilities: record.source.capabilities,
                precedence: record.source.precedence,
                accessState: record.accessState,
                authority: record.authority,
                validationToken: record.validationToken,
                itemGeneration: record.itemGeneration
            )
        }
        return LibrarySourcePersistenceSignature(
            sourceSetAuthority: sourceSetAuthority,
            entries: entries,
            additionalStateGeneration: additionalStateGeneration
        )
    }

    /// Captures last-reference state once before a coordinator applies a batch.
    package func captureChangeBaseline() -> LibrarySourceChangeBaseline {
        LibrarySourceChangeBaseline(epoch: epoch, retentionUIDs: retentionUIDs())
    }

    /// Builds one consumer change after a coordinator-owned mutation batch.
    package func snapshot(since baseline: LibrarySourceChangeBaseline) -> LibrarySourceChange {
        guard baseline.epoch == epoch else { return snapshot() }
        return makeChange(previousRetentionUIDs: baseline.retentionUIDs)
    }

    /// Current immutable consumer view without mutating authority or generations.
    /// Coordinators use this for initial binding before the first remote refresh completes.
    public func snapshot() -> LibrarySourceChange {
        let retained = retentionUIDs()
        return makeChange(previousRetentionUIDs: retained)
    }

    /// Selects a stable capability route without scanning the resource inventory.
    public func accessLease(
        for uid: PhotoUID,
        requiring capability: LibrarySourceCapabilities,
        includeExcludedSources: Bool = true
    ) -> SourceAccessLease? {
        guard !capability.isEmpty, capability.subtracting(.all).isEmpty else { return nil }
        var selectedID: SourceID?
        for (sourceID, record) in records
        where record.accessState != .accessLost
            && (includeExcludedSources || record.source.isIncluded)
            && record.source.capabilities.contains(capability)
            && record.itemIndexByUID[uid] != nil
        {
            if let selectedID, let selected = records[selectedID],
                !LibrarySourceProjection.sourcePrecedes(record.source, selected.source)
            {
                continue
            }
            selectedID = sourceID
        }
        guard let selectedID, let record = records[selectedID] else { return nil }
        return SourceAccessLease(
            sourceID: selectedID,
            uid: uid,
            capability: capability,
            epoch: epoch,
            generation: record.accessGeneration,
            requiresInclusion: !includeExcludedSources,
            membershipUID: uid,
            relationship: nil
        )
    }

    /// Issues a target-resource lease through the exact source that proved its owning relationship.
    /// This prevents a higher-precedence source with unrelated content from receiving another source's node ID.
    public func relatedAccessLease(
        for resourceUID: PhotoUID,
        of ownerUID: PhotoUID,
        relationship: LibrarySourceRelationship,
        requiring capability: LibrarySourceCapabilities,
        includeExcludedSources: Bool = true
    ) -> SourceAccessLease? {
        guard !capability.isEmpty, capability.subtracting(.all).isEmpty,
            resourceUID.volumeID == ownerUID.volumeID
        else { return nil }
        var selectedID: SourceID?
        for (sourceID, record) in records {
            guard record.accessState != .accessLost,
                includeExcludedSources || record.source.isIncluded,
                record.source.capabilities.contains(capability),
                let itemIndex = record.itemIndexByUID[ownerUID],
                Self.establishes(
                    relationship,
                    from: ownerUID,
                    to: resourceUID,
                    sourceItem: record.items[itemIndex]
                )
            else { continue }
            if let selectedID, let selected = records[selectedID],
                !LibrarySourceProjection.sourcePrecedes(record.source, selected.source)
            {
                continue
            }
            selectedID = sourceID
        }
        guard let selectedID, let record = records[selectedID] else { return nil }
        return SourceAccessLease(
            sourceID: selectedID,
            uid: resourceUID,
            capability: capability,
            epoch: epoch,
            generation: record.accessGeneration,
            requiresInclusion: !includeExcludedSources,
            membershipUID: ownerUID,
            relationship: relationship
        )
    }

    /// Issues leases for burst members through the source items that list them. Burst members are not library
    /// items, so `accessLease(for:)` refuses them; each lease stays bound to the owning item's relationship.
    public func burstMemberAccessLeases(
        for memberUIDs: Set<PhotoUID>,
        requiring capability: LibrarySourceCapabilities,
        includeExcludedSources: Bool = true
    ) -> [PhotoUID: SourceAccessLease] {
        guard !memberUIDs.isEmpty else { return [:] }
        var ownersByMember: [PhotoUID: [PhotoUID]] = [:]
        for record in records.values
        where record.accessState != .accessLost
            && (includeExcludedSources || record.source.isIncluded)
            && record.source.capabilities.contains(capability)
        {
            for memberUID in memberUIDs {
                if let owners = record.burstOwnersByMemberUID[memberUID] {
                    ownersByMember[memberUID, default: []].append(contentsOf: owners)
                }
            }
        }
        var leases: [PhotoUID: SourceAccessLease] = [:]
        for (memberUID, ownerUIDs) in ownersByMember {
            for ownerUID in ownerUIDs {
                if let lease = relatedAccessLease(
                    for: memberUID,
                    of: ownerUID,
                    relationship: .burstMember,
                    requiring: capability,
                    includeExcludedSources: includeExcludedSources
                ) {
                    leases[memberUID] = lease
                    break
                }
            }
        }
        return leases
    }

    /// The same route as `lease`, issued from the graph as it is now: the same photo, capability, source, and
    /// relationship owner, or the same Recently Deleted registration. Nil when the graph no longer authorizes that
    /// route. A delivery fence uses it for a result that arrives after an inventory refresh changed any item.
    ///
    /// Renewal authorizes by the current state only. It deliberately accepts a route that was removed and added
    /// again, or a source reactivated after access loss, while the result was in flight, because the graph
    /// authorizes that route now. It also returns nil when a source of higher precedence now serves the photo,
    /// although the original source still lists it; the caller withholds the result and requests it again. Use it
    /// only for reads whose bytes depend on the photo identity alone, such as thumbnails; a consumer that needs the
    /// remove-then-readd fence must keep checking `isCurrent(_:)`.
    public func renewed(_ lease: SourceAccessLease) -> SourceAccessLease? {
        guard lease.epoch == epoch else { return nil }
        let includeExcludedSources = !lease.requiresInclusion
        let renewed: SourceAccessLease?
        if lease.readsIdentityOutsideInventory {
            renewed =
                identityOutsideInventoryAccessLeases(
                    for: [lease.uid], requiring: lease.capability, includeExcludedSources: includeExcludedSources
                )[lease.uid]
        } else if let relationship = lease.relationship {
            renewed = relatedAccessLease(
                for: lease.uid,
                of: lease.membershipUID,
                relationship: relationship,
                requiring: lease.capability,
                includeExcludedSources: includeExcludedSources
            )
        } else {
            renewed = accessLease(
                for: lease.uid, requiring: lease.capability, includeExcludedSources: includeExcludedSources)
        }
        guard let renewed, renewed.sourceID == lease.sourceID else { return nil }
        return renewed
    }

    /// Checks the lease again before publishing a late asynchronous result.
    public func isCurrent(_ lease: SourceAccessLease) -> Bool {
        guard lease.epoch == epoch, let record = records[lease.sourceID] else { return false }
        guard record.accessState != .accessLost,
            record.accessGeneration == lease.generation,
            record.source.capabilities.contains(lease.capability),
            !lease.requiresInclusion || record.source.isIncluded
        else { return false }
        if lease.readsIdentityOutsideInventory {
            // No inventory lists this identity. The registration of its route is the only membership proof.
            return identitiesOutsideInventory.contains(lease.uid)
        }
        return record.itemIndexByUID[lease.membershipUID] != nil
            && isCurrentRelationship(lease, record: record)
    }

    private func isCurrentRelationship(_ lease: SourceAccessLease, record: Record) -> Bool {
        guard let relationship = lease.relationship else { return lease.uid == lease.membershipUID }
        guard let itemIndex = record.itemIndexByUID[lease.membershipUID] else {
            return false
        }
        let sourceItem = record.items[itemIndex]
        return Self.establishes(
            relationship,
            from: lease.membershipUID,
            to: lease.uid,
            sourceItem: sourceItem
        )
    }

    private static func establishes(
        _ relationship: LibrarySourceRelationship,
        from ownerUID: PhotoUID,
        to resourceUID: PhotoUID,
        sourceItem: LibrarySourceItem
    ) -> Bool {
        guard ownerUID.volumeID == resourceUID.volumeID,
            sourceItem.uid == ownerUID,
            sourceItem.knownFields.contains(relationship.metadataField)
        else { return false }
        switch relationship {
        case .livePhotoMotion:
            return sourceItem.item.relatedVideoID == resourceUID.nodeID
        case .burstMember:
            return sourceItem.item.burstMemberIDs.contains(resourceUID.nodeID)
        }
    }

    public func selectedProjection() -> LibrarySourceProjection {
        makeProjection(records: selectedRecords())
    }

    /// All still-accessible sources, including sources excluded from the main projection.
    public func retentionProjection() -> LibrarySourceProjection {
        makeProjection(records: retentionRecords())
    }

    public func selectedDerivedDataScope() -> SelectedDerivedDataScope {
        let included = selectedRecords()
        return makeScope(
            records: included,
            orderedUIDs: makeProjection(records: included).timeline.uids
        )
    }

    /// All accessible thumbnail-capable identities, including sources excluded from the main projection.
    public func analysisDerivedDataScope() -> AnalysisDerivedDataScope {
        let included = retentionRecords().filter { $0.source.capabilities.contains(.readThumbnail) }
        return makeScope(
            records: included,
            orderedUIDs: Self.membershipOrder(records: included),
            requiredCapability: .readThumbnail
        )
    }

    public func retentionDerivedDataScope() -> RetentionDerivedDataScope {
        let included = retentionRecords()
        return makeScope(
            records: included,
            orderedUIDs: Self.membershipOrder(records: included)
        )
    }

    public func thumbnailRetentionDerivedDataScope() -> ThumbnailRetentionDerivedDataScope {
        let included = retentionRecords().filter {
            $0.source.capabilities.contains(.readThumbnail)
        }
        return makeScope(
            records: included,
            orderedUIDs: Self.relationshipRetentionOrder(
                records: included,
                relationship: .burstMember
            ),
            // A photo in the volume trash left every inventory but stays visible in Recently Deleted.
            // Its thumbnail stays on disk; the crawl fetches it after every library photo.
            authorizationOnlyUIDs: included.isEmpty ? [] : identitiesOutsideInventoryOrder,
            requiredCapability: .readThumbnail
        )
    }

    public func videoRetentionDerivedDataScope() -> VideoRetentionDerivedDataScope {
        let included = retentionRecords().filter {
            $0.source.capabilities.contains(.readContent)
        }
        return makeScope(
            records: included,
            orderedUIDs: Self.relationshipRetentionOrder(
                records: included,
                relationship: .livePhotoMotion
            ),
            requiredCapability: .readContent
        )
    }

    private func makeChange(previousRetentionUIDs: Set<PhotoUID>) -> LibrarySourceChange {
        let retentionRecords = retentionRecords()
        let selectedRecords = retentionRecords.filter { $0.source.isIncluded }
        let retentionProjection = makeProjection(records: retentionRecords)
        let selectedProjection =
            selectedRecords.count == retentionRecords.count
            ? retentionProjection : makeProjection(records: selectedRecords)
        let retentionOrder = Self.membershipOrder(records: retentionRecords)
        let selectedScope: SelectedDerivedDataScope = makeScope(
            records: selectedRecords,
            orderedUIDs: selectedProjection.timeline.uids
        )
        let analysisRecords = retentionRecords.filter {
            $0.source.capabilities.contains(.readThumbnail)
        }
        let analysisOrder =
            analysisRecords.count == retentionRecords.count
            ? retentionOrder : Self.membershipOrder(records: analysisRecords)
        let analysisScope: AnalysisDerivedDataScope = makeScope(
            records: analysisRecords,
            orderedUIDs: analysisOrder,
            requiredCapability: .readThumbnail
        )
        let retentionScope: RetentionDerivedDataScope = makeScope(
            records: retentionRecords,
            orderedUIDs: retentionOrder
        )
        let thumbnailRetentionScope: ThumbnailRetentionDerivedDataScope = makeScope(
            records: analysisRecords,
            orderedUIDs: Self.relationshipRetentionOrder(
                records: analysisRecords,
                relationship: .burstMember,
                directOrder: analysisOrder
            ),
            // Recently Deleted reads photos that left every inventory. They authorize reads, keep their bytes,
            // and stay out of every analysis order.
            authorizationOnlyUIDs: analysisRecords.isEmpty ? [] : identitiesOutsideInventoryOrder,
            requiredCapability: .readThumbnail
        )
        let videoRecords = retentionRecords.filter {
            $0.source.capabilities.contains(.readContent)
        }
        let videoRetentionScope: VideoRetentionDerivedDataScope = makeScope(
            records: videoRecords,
            orderedUIDs: Self.relationshipRetentionOrder(
                records: videoRecords,
                relationship: .livePhotoMotion,
                directOrder: videoRecords.count == retentionRecords.count
                    ? retentionOrder : Self.membershipOrder(records: videoRecords)
            ),
            requiredCapability: .readContent
        )
        return LibrarySourceChange(
            selectedProjection: selectedProjection,
            retentionProjection: retentionProjection,
            selectedScope: selectedScope,
            analysisScope: analysisScope,
            retentionScope: retentionScope,
            thumbnailRetentionScope: thumbnailRetentionScope,
            videoRetentionScope: videoRetentionScope,
            orphanedUIDs: retentionScope.isAuthoritative
                ? previousRetentionUIDs.subtracting(retentionScope.uids) : []
        )
    }

    private func selectedRecords() -> [Record] {
        records.values.filter { $0.source.isIncluded && $0.accessState != .accessLost }.sorted { lhs, rhs in
            LibrarySourceProjection.sourcePrecedes(lhs.source, rhs.source)
        }
    }

    private func retentionRecords() -> [Record] {
        records.values.filter { $0.accessState != .accessLost }.sorted { lhs, rhs in
            LibrarySourceProjection.sourcePrecedes(lhs.source, rhs.source)
        }
    }

    private func makeProjection(records included: [Record]) -> LibrarySourceProjection {
        var itemsByUID: [PhotoUID: LibrarySourceItem] = [:]
        var membershipsByUID: [PhotoUID: Set<SourceID>] = [:]
        var sourcesByID: [SourceID: LibrarySource] = [:]
        var metadataProvenanceByUID: [PhotoUID: [LibrarySourceMetadataFields: SourceID]] = [:]
        let itemCapacity = included.reduce(into: 0) { $0 += $1.items.count }
        itemsByUID.reserveCapacity(itemCapacity)
        membershipsByUID.reserveCapacity(itemCapacity)
        sourcesByID.reserveCapacity(included.count)
        metadataProvenanceByUID.reserveCapacity(itemCapacity)

        for record in included {
            sourcesByID[record.source.id] = record.source
            for item in record.items {
                membershipsByUID[item.uid, default: []].insert(record.source.id)
                if let preferred = itemsByUID[item.uid] {
                    for field in LibrarySourceMetadataFields.individualFields
                    where !preferred.knownFields.contains(field) && item.knownFields.contains(field) {
                        metadataProvenanceByUID[item.uid, default: [:]][field] = record.source.id
                    }
                    itemsByUID[item.uid] = Self.merge(preferred: preferred, fallback: item)
                } else {
                    itemsByUID[item.uid] = item
                    for field in LibrarySourceMetadataFields.individualFields
                    where item.knownFields.contains(field) {
                        metadataProvenanceByUID[item.uid, default: [:]][field] = record.source.id
                    }
                }
            }
        }

        let projectedItems = itemsByUID.values.filter {
            $0.knownFields.contains(.requiredForProjection)
        }
        let projectedUIDs = Set(projectedItems.map(\.uid))
        itemsByUID = itemsByUID.filter { projectedUIDs.contains($0.key) }
        membershipsByUID = membershipsByUID.filter { projectedUIDs.contains($0.key) }
        metadataProvenanceByUID = metadataProvenanceByUID.filter {
            projectedUIDs.contains($0.key)
        }
        let orderedItems = TimelineSnapshot(orderedItems: projectedItems.map(\.item)).items
        let sections =
            orderedItems.isEmpty
            ? []
            : [
                TimelineSection(
                    id: "library",
                    date: orderedItems[0].captureTime,
                    title: "",
                    items: orderedItems
                )
            ]
        return LibrarySourceProjection(
            timeline: TimelineContentProjection(sections: sections),
            metadataByUID: itemsByUID,
            membershipsByUID: membershipsByUID,
            sourcesByID: sourcesByID,
            metadataProvenanceByUID: metadataProvenanceByUID
        )
    }

    private func makeScope<Kind: DerivedDataScopeKind>(
        records included: [Record],
        orderedUIDs: [PhotoUID],
        authorizationOnlyUIDs: [PhotoUID] = [],
        requiredCapability: LibrarySourceCapabilities = []
    ) -> DerivedDataScope<Kind> {
        let sourceIDs = Set(included.map(\.source.id))
        let authoritative =
            sourceSetAuthority == .authoritative
            && included.allSatisfy {
                $0.accessState == .available && $0.authority == .authoritative
                    && $0.source.capabilities.contains(requiredCapability)
            }
        return DerivedDataScope<Kind>(
            epoch: epoch,
            sourceIDs: sourceIDs,
            orderedUIDs: orderedUIDs,
            authorizationOnlyUIDs: authorizationOnlyUIDs,
            isAuthoritative: authoritative,
            revision: revision
        )
    }

    private func retentionUIDs() -> Set<PhotoUID> {
        Set(retentionRecords().flatMap { $0.items.map(\.uid) })
    }

    /// Builds a relationship-resource keep-set from every membership, not from the merged projection.
    /// Conflicting complete relationships can therefore coexist without precedence deleting either target.
    private static func relationshipRetentionOrder(
        records: [Record],
        relationship: LibrarySourceRelationship,
        directOrder: [PhotoUID]? = nil
    ) -> [PhotoUID] {
        var relatedByOwner: [PhotoUID: [PhotoUID]] = [:]
        let directOrder = directOrder ?? membershipOrder(records: records)
        relatedByOwner.reserveCapacity(directOrder.count)
        for record in records
        where record.source.capabilities.contains(
            relationship == .livePhotoMotion ? .readContent : .readThumbnail
        ) {
            for sourceItem in record.items
            where sourceItem.knownFields.contains(relationship.metadataField) {
                switch relationship {
                case .livePhotoMotion:
                    if let relatedVideoUID = sourceItem.item.relatedVideoUID {
                        relatedByOwner[sourceItem.uid, default: []].append(relatedVideoUID)
                    }
                case .burstMember:
                    relatedByOwner[sourceItem.uid, default: []].append(
                        contentsOf: sourceItem.item.burstMemberUIDs
                    )
                }
            }
        }
        var ordered: [PhotoUID] = []
        ordered.reserveCapacity(directOrder.count + relatedByOwner.values.reduce(0) { $0 + $1.count })
        for uid in directOrder {
            ordered.append(uid)
            if let related = relatedByOwner[uid] { ordered.append(contentsOf: related) }
        }
        return ordered
    }

    private static func membershipOrder(records: [Record]) -> [PhotoUID] {
        // Every record already owns a unique, canonically sorted inventory. The common single-source
        // path needs neither another identity dictionary nor a sort.
        if records.count == 1 { return records[0].items.map(\.uid) }
        var bestByUID: [PhotoUID: LibrarySourceItem] = [:]
        for record in records {
            for item in record.items where bestByUID[item.uid] == nil {
                bestByUID[item.uid] = item
            }
        }
        return bestByUID.values.sorted(by: sourceItemPrecedes).map(\.uid)
    }

    private static func canonicalItems(
        _ items: [LibrarySourceItem],
        preservingKnownFieldsFrom previousItems: [LibrarySourceItem] = []
    ) -> [LibrarySourceItem] {
        let previousByUID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.uid, $0) })
        var firstByUID: [PhotoUID: LibrarySourceItem] = [:]
        firstByUID.reserveCapacity(items.count)
        for item in items where firstByUID[item.uid] == nil {
            if let previous = previousByUID[item.uid] {
                firstByUID[item.uid] = merge(preferred: item, fallback: previous)
            } else {
                firstByUID[item.uid] = item
            }
        }
        return firstByUID.values.sorted(by: sourceItemPrecedes)
    }

    private static func sourceItemPrecedes(_ lhs: LibrarySourceItem, _ rhs: LibrarySourceItem) -> Bool {
        let lhsHasTime = lhs.knownFields.contains(.captureTime)
        let rhsHasTime = rhs.knownFields.contains(.captureTime)
        if lhsHasTime != rhsHasTime { return lhsHasTime }
        if lhsHasTime {
            let lhsTime = lhs.item.captureTime.timeIntervalSince1970
            let rhsTime = rhs.item.captureTime.timeIntervalSince1970
            if lhsTime != rhsTime { return lhsTime < rhsTime }
        }
        if lhs.uid.volumeID != rhs.uid.volumeID {
            return lhs.uid.volumeID.utf8.lexicographicallyPrecedes(rhs.uid.volumeID.utf8)
        }
        return lhs.uid.nodeID.utf8.lexicographicallyPrecedes(rhs.uid.nodeID.utf8)
    }

    private static func burstOwnersByMemberUID(_ items: [LibrarySourceItem]) -> [PhotoUID: [PhotoUID]] {
        let relationshipField = LibrarySourceRelationship.burstMember.metadataField
        var owners: [PhotoUID: [PhotoUID]] = [:]
        for sourceItem in items
        where sourceItem.knownFields.contains(relationshipField) && !sourceItem.item.burstMemberIDs.isEmpty {
            for nodeID in sourceItem.item.burstMemberIDs {
                owners[PhotoUID(volumeID: sourceItem.uid.volumeID, nodeID: nodeID), default: []].append(sourceItem.uid)
            }
        }
        return owners
    }

    private static func itemIndexByUID(_ items: [LibrarySourceItem]) -> [PhotoUID: Int] {
        var result: [PhotoUID: Int] = [:]
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            result[item.uid] = index
        }
        return result
    }

    private static func isValidEnumeration(_ items: [LibrarySourceItem]) -> Bool {
        items.allSatisfy(LibrarySourceInventoryValidator.hasValidItem)
            && Set(items.map(\.uid)).count == items.count
    }

    /// Higher-precedence known fields win. A lower-precedence source fills only fields which the
    /// preferred source marked unknown; known empty tags and relationships remain authoritative.
    private static func merge(
        preferred: LibrarySourceItem,
        fallback: LibrarySourceItem
    ) -> LibrarySourceItem {
        let preferredItem = preferred.item
        let fallbackItem = fallback.item
        let knownFields = preferred.knownFields.union(fallback.knownFields)

        return LibrarySourceItem(
            item: PhotoItem(
                uid: preferred.uid,
                captureTime: preferred.knownFields.contains(.captureTime)
                    ? preferredItem.captureTime : fallbackItem.captureTime,
                mediaType: preferred.knownFields.contains(.mediaType)
                    ? preferredItem.mediaType : fallbackItem.mediaType,
                isLivePhoto: preferred.knownFields.contains(.livePhotoRelationship)
                    ? preferredItem.isLivePhoto : fallbackItem.isLivePhoto,
                relatedVideoID: preferred.knownFields.contains(.livePhotoRelationship)
                    ? preferredItem.relatedVideoID : fallbackItem.relatedVideoID,
                durationSeconds: preferred.knownFields.contains(.duration)
                    ? preferredItem.durationSeconds : fallbackItem.durationSeconds,
                tags: preferred.knownFields.contains(.tags) ? preferredItem.tags : fallbackItem.tags,
                burstMemberIDs: preferred.knownFields.contains(.burstRelationship)
                    ? preferredItem.burstMemberIDs : fallbackItem.burstMemberIDs,
                timelineOrder: preferredItem.timelineOrder ?? fallbackItem.timelineOrder
            ),
            knownFields: knownFields
        )
    }

    private static func sourceIDPrecedes(_ lhs: SourceID, _ rhs: SourceID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}
