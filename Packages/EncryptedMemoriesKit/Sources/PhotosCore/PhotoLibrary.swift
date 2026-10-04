import Foundation

/// Proton's built-in photo tags (server-side smart filters). Raw values are the API's PhotoTag enum.
public enum PhotoTag: Int, Sendable, CaseIterable, Codable {
    case favorites = 0
    case screenshots = 1
    case videos = 2
    case livePhotos = 3
    case motionPhotos = 4
    case selfies = 5
    case portraits = 6
    case bursts = 7
    case panoramas = 8
    case raw = 9

    public var title: String {
        switch self {
        case .favorites: L10n.string("tag.favorites")
        case .screenshots: L10n.string("tag.screenshots")
        case .videos: L10n.string("tag.videos")
        case .livePhotos: L10n.string("tag.live_photos")
        case .motionPhotos: L10n.string("tag.motion")
        case .selfies: L10n.string("tag.selfies")
        case .portraits: L10n.string("tag.portraits")
        case .bursts: L10n.string("tag.bursts")
        case .panoramas: L10n.string("tag.panoramas")
        case .raw: L10n.string("tag.raw")
        }
    }

    public var systemImage: String {
        switch self {
        case .favorites: "heart"
        case .screenshots: "camera.viewfinder"
        case .videos: "video"
        case .livePhotos: "livephoto"
        case .motionPhotos: "livephoto.play"  // was "circle.motionlines" - not a real SF Symbol, so it rendered blank
        case .selfies: "person.crop.square"
        case .portraits: "person.fill"
        case .bursts: "square.stack.3d.down.right"
        case .panoramas: "pano"
        case .raw: "r.square"
        }
    }
}

/// What the grid is currently showing - the whole library, a smart-filter tag, an album, or trash.
public enum PhotoFilter: Equatable, Hashable, Sendable {
    case all
    case tag(PhotoTag)
    case album(id: String, title: String)
    /// A read-only album shared with the account. Lossless volume + node identity because the album lives on
    /// another user's volume; contents come from the SDK, never from the owned-volume HTTP album route.
    case sharedAlbum(volumeID: String, nodeID: String, title: String)
    case trash
    /// The whole-library Map view - no timeline load; the detail shows the map instead.
    case map
    /// Groups of exact copies - no timeline load; the detail shows the Duplicates screen instead.
    case duplicates

    /// True for routes whose items live on another account's volume. Every mutation (trash, favorite,
    /// album membership, cover) targets the owned volume and must stay hidden on these routes.
    public var isReadOnly: Bool {
        if case .sharedAlbum = self { return true }
        return false
    }

    /// Whether selecting this route should load timeline sections into the Metal grid.
    public var hasTimeline: Bool {
        switch self {
        case .map, .duplicates: false
        default: true
        }
    }
}

/// Shared empty-state copy for every timeline route. Platform views own only the native
/// presentation surface; the text and symbolic image live here so macOS, iOS and iPadOS cannot drift.
public struct PhotoFilterEmptyStateCopy: Equatable, Sendable {
    public let title: String
    public let description: String
    public let systemImage: String

    public init(title: String, description: String, systemImage: String) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
    }
}

public extension PhotoFilter {
    var emptyStateCopy: PhotoFilterEmptyStateCopy {
        switch self {
        case .all:
            PhotoFilterEmptyStateCopy(
                title: L10n.string("empty.no_photos_title"),
                description: L10n.string("empty.no_photos_description"),
                systemImage: "photo.on.rectangle.angled"
            )
        case .tag(let tag):
            PhotoFilterEmptyStateCopy(
                title: L10n.string("empty.filter_title \(tag.title)"),
                description: L10n.string("empty.filter_description"),
                systemImage: tag.systemImage
            )
        case .album, .sharedAlbum:
            PhotoFilterEmptyStateCopy(
                title: L10n.string("empty.album_title"),
                description: L10n.string("empty.album_description"),
                systemImage: "rectangle.stack"
            )
        case .trash:
            PhotoFilterEmptyStateCopy(
                title: L10n.string("empty.trash_title"),
                description: L10n.string("empty.trash_description"),
                systemImage: "trash"
            )
        case .map:
            PhotoFilterEmptyStateCopy(
                title: L10n.string("empty.no_photos_title"),
                description: L10n.string("empty.no_photos_description"),
                systemImage: "map"
            )
        case .duplicates:
            PhotoFilterEmptyStateCopy(
                title: L10n.string("duplicates.none_title"),
                description: L10n.string("duplicates.none_message"),
                systemImage: "square.on.square"
            )
        }
    }
}

public struct FavoriteMutationError: LocalizedError, Sendable, Equatable {
    public let succeeded: Set<PhotoUID>
    public let failed: Set<PhotoUID>
    public let diagnosticMessage: String

    public init(succeeded: Set<PhotoUID>, failed: Set<PhotoUID>, diagnosticMessage: String) {
        self.succeeded = succeeded
        self.failed = failed
        self.diagnosticMessage = diagnosticMessage
    }

    public var errorDescription: String? {
        L10n.string("error.favorite_update_failed")
    }
}

/// Read + write of the favorites tag. Reads retain the Photos tag listing because SDK 0.29.1 does
/// not expose complete timeline tags; writes use one SDK `updatePhotos` batch and validate every
/// per-node result.
public protocol FavoritesProvider: Sendable {
    func favoriteUIDs() async throws -> Set<PhotoUID>
    func setFavorites(_ uids: [PhotoUID], _ favorite: Bool) async throws
}

public extension FavoritesProvider {
    func setFavorite(_ uid: PhotoUID, _ favorite: Bool) async throws {
        try await setFavorites([uid], favorite)
    }
}

/// Result of one "Save to Library" request. Every requested photo is either saved or failed.
public struct PhotoLibrarySaveResult: Sendable, Equatable {
    public let saved: Set<PhotoUID>
    public let failed: Set<PhotoUID>

    public init(saved: Set<PhotoUID>, failed: Set<PhotoUID>) {
        self.saved = saved
        self.failed = failed
    }

    /// Localized outcome for the banner or alert that follows the request.
    public var message: String {
        if failed.isEmpty {
            return saved.count == 1
                ? L10n.string("library.save_to_library_done_one")
                : L10n.string("library.save_to_library_done_many \(saved.count)")
        }
        return L10n.string("library.save_to_library_partial \(failed.count) \(saved.count + failed.count)")
    }
}

/// Copies photos from another account's shared album into the signed-in account's own photo library.
/// The backend also copies Live Photo and burst companions and reports one outcome per requested photo.
public protocol PhotoLibrarySaving: Sendable {
    func saveToLibrary(_ uids: [PhotoUID]) async throws -> PhotoLibrarySaveResult
}

/// Move photos to / restore from the Proton trash.
public protocol TrashProvider: Sendable {
    func trash(_ uids: [PhotoUID]) async throws
    func restore(_ uids: [PhotoUID]) async throws
    func emptyTrash() async throws
}

/// Optional backend capability: load a filtered/album timeline. Album catalog reads live in
/// AlbumCore's SDK-backed repository; tag/album contents retain the direct Photos endpoints because
/// SDK 0.29.1 omits Tags and RelatedPhotos needed for Live Photos and bursts.
public protocol PhotoLibraryProvider: Sendable {
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection]
}
