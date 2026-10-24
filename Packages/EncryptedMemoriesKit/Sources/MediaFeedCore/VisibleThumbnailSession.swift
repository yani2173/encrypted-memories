import Foundation
import MediaDecodingCore
import PhotosCore

/// One visible photo. Selection and close revoke its access without changing the library grid.
@MainActor
public final class VisibleThumbnailSession {
    private let feed: ThumbnailFeedCore
    private var uid: PhotoUID?
    private var access: VisibleThumbnailAccess?

    public init(feed: ThumbnailFeedCore) { self.feed = feed }

    public func select(_ uid: PhotoUID?) {
        access?.end()
        self.uid = uid
        access = uid.map { feed.beginVisibleThumbnailAccess(for: $0) }
    }

    public func end() { select(nil) }

    /// Opens the access for `uid` when it is not open, for example when a viewer appears again after a cover over it
    /// closed. An open access for the same photo stays, so a load that holds it goes on.
    public func reopen(_ uid: PhotoUID?) {
        guard uid != self.uid else { return }
        select(uid)
    }

    public func memoryDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        guard self.uid == uid, let access else { return nil }
        return feed.memoryDecoded(for: uid, access: access)
    }

    public func cachedDecoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        guard self.uid == uid, let access else { return nil }
        let image = await feed.cachedDecoded(for: uid, access: access)
        guard self.uid == uid, self.access === access else { return nil }
        return image
    }

    public func visibleDecoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        guard self.uid == uid, let access else { return nil }
        let image = await feed.visibleDecoded(for: uid, access: access)
        guard self.uid == uid, self.access === access else { return nil }
        return image
    }
}
