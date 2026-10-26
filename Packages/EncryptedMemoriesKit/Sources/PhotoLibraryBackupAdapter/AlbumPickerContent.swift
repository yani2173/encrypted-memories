import AlbumSyncCore
import Foundation

/// What the album picker shows. The Mac sheet and the iOS sheet decide it the same way and draw each case in
/// their own native form.
public enum AlbumPickerContent: Equatable, Sendable {
    /// The first load of the albums is still running.
    case loading
    /// Photos access is denied or restricted, so no album can be listed.
    case accessDenied
    /// No album exists, or none matches the search.
    case empty
    case list([LocalAlbumSummary])

    /// The albums whose title contains the query, ignoring case and the spaces around the query. A blank query keeps
    /// every album.
    public static func albums(_ albums: [LocalAlbumSummary], matching query: String) -> [LocalAlbumSummary] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return albums }
        return albums.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Loading wins until the sheet has loaded once, then denied or restricted access, then the empty state, and
    /// otherwise the list of matching albums.
    public static func resolve(
        albums: [LocalAlbumSummary], query: String, isLoading: Bool, didLoad: Bool, accessState: PhotoBackupAccessState
    ) -> AlbumPickerContent {
        if isLoading && !didLoad { return .loading }
        if accessState == .denied || accessState == .restricted { return .accessDenied }
        let matching = Self.albums(albums, matching: query)
        return matching.isEmpty ? .empty : .list(matching)
    }
}

extension AlbumSyncController {
    /// What the album picker shows for the controller's albums, load state and photos access.
    public func pickerContent(matching query: String, didLoad: Bool) -> AlbumPickerContent {
        AlbumPickerContent.resolve(
            albums: availableAlbums, query: query, isLoading: isLoadingAlbums, didLoad: didLoad,
            accessState: accessState)
    }
}
