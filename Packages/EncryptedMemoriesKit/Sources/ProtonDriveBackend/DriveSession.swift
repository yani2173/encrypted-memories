import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreDataModel

/// Holds the live Proton session and performs authenticated requests against the Drive API,
/// transparently refreshing the access token on 401. Shared by the SDK HTTP client and the
/// account-data fetch. Thread-safe (token state guarded by a lock).
final class DriveSession: @unchecked Sendable {
    let config: ProtonAPIConfig
    private let store: SessionKeychainStore
    private let accountCacheDirectory: URL
    private let urlSession: URLSession
    private let storageSession: URLSession
    let requestGovernor: ProtonRequestGovernor
    private let lock = NSLock()
    private var session: ProtonSession
    private var refreshing: Task<Bool, Never>?

    init(
        session: ProtonSession,
        store: SessionKeychainStore,
        config: ProtonAPIConfig = ProtonAPIConfig(),
        accountCacheDirectory: URL,
        requestGovernor: ProtonRequestGovernor = ProtonRequestGovernor(),
        urlProtocolClasses: [AnyClass]? = nil
    ) {
        self.session = session
        self.store = store
        self.config = config
        self.accountCacheDirectory = accountCacheDirectory
        self.requestGovernor = requestGovernor
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Accept": "application/vnd.protonmail.v1+json"]
        // Test seam: lets unit tests intercept requests with a URLProtocol stub (never set in production).
        if let urlProtocolClasses { cfg.protocolClasses = urlProtocolClasses }
        self.urlSession = URLSession(configuration: cfg)
        let storageConfiguration = URLSessionConfiguration.ephemeral
        if let urlProtocolClasses { storageConfiguration.protocolClasses = urlProtocolClasses }
        self.storageSession = URLSession(configuration: storageConfiguration)
    }

    var current: ProtonSession { lock.withLock { session } }
    var keyPassword: String { lock.withLock { session.keyPassword } }

    /// Builds an absolute API URL. Uses string concatenation rather than
    /// `URL.appendingPathComponent`, which would percent-encode `?`/`&` in the query string.
    func makeURL(_ path: String) -> URL {
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: config.baseURL.absoluteString + p) ?? config.baseURL
    }

    /// Auth headers for an arbitrary request (used by the SDK HTTP client too).
    func authHeaders() -> [String: String] {
        let s = current
        return [
            "x-pm-uid": s.uid,
            "Authorization": "Bearer \(s.accessToken)",
            "x-pm-appversion": config.appVersion,
        ]
    }

    // MARK: - Authenticated JSON

    func getJSON<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await authedData(path: path, method: "GET", retryOn429: true)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Authenticated write request (POST/PUT/DELETE) with an optional JSON body.
    @discardableResult
    func send(
        _ path: String,
        method: String,
        body: [String: Any]? = nil,
        retryOnRateLimit: Bool = false
    ) async throws -> Data {
        try await authedData(
            path: path,
            method: method,
            body: body,
            retryOn429: retryOnRateLimit
        )
    }

    private func authedData(
        path: String,
        method: String,
        body: [String: Any]? = nil,
        retryOn401: Bool = true,
        retryOn429: Bool
    ) async throws -> Data {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = method
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let permit = try await requestGovernor.acquire(scope: .api)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            await requestGovernor.finish(permit, statusCode: nil)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            await requestGovernor.finish(permit, statusCode: nil)
            throw ProtonAuthError.invalidResponse
        }
        await requestGovernor.finish(
            permit,
            statusCode: http.statusCode,
            retryAfter: ProtonRetryAfter.seconds(from: http)
        )

        if http.statusCode == 429, retryOn429 {
            return try await authedData(
                path: path,
                method: method,
                body: body,
                retryOn401: retryOn401,
                retryOn429: false
            )
        }

        if http.statusCode == 401, retryOn401 {
            if await refreshToken() {
                return try await authedData(
                    path: path,
                    method: method,
                    body: body,
                    retryOn401: false,
                    retryOn429: retryOn429
                )
            }
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProtonAuthError.apiError(code: http.statusCode, message: "HTTP \(http.statusCode) for \(path)")
        }
        return data
    }

    // MARK: - Token refresh

    func refreshToken() async -> Bool {
        let task: Task<Bool, Never> = lock.withLock {
            if let existing = refreshing { return existing }
            let t = Task<Bool, Never> { await self.performRefresh() }
            refreshing = t
            return t
        }
        let result = await task.value
        lock.withLock { refreshing = nil }
        return result
    }

    private func performRefresh() async -> Bool {
        let s = current
        var req = URLRequest(url: makeURL("/auth/v4/refresh"))
        req.httpMethod = "POST"
        req.setValue(config.appVersion, forHTTPHeaderField: "x-pm-appversion")
        req.setValue(s.uid, forHTTPHeaderField: "x-pm-uid")
        req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ResponseType": "token", "GrantType": "refresh_token", "RefreshToken": s.refreshToken,
        ])
        guard let permit = try? await requestGovernor.acquire(scope: .api, priority: .immediate)
        else { return false }
        guard let (data, response) = try? await urlSession.data(for: req),
            let http = response as? HTTPURLResponse
        else {
            await requestGovernor.finish(permit, statusCode: nil)
            return false
        }
        await requestGovernor.finish(
            permit,
            statusCode: http.statusCode,
            retryAfter: ProtonRetryAfter.seconds(from: http)
        )
        guard (200...299).contains(http.statusCode),
            let body = try? JSONDecoder().decode(RefreshResponse.self, from: data),
            let at = body.accessToken
        else {
            return false
        }
        var refreshed = s
        refreshed.accessToken = at
        if let rt = body.refreshToken { refreshed.refreshToken = rt }
        guard (try? store.save(refreshed)) != nil else { return false }
        lock.withLock { session = refreshed }
        return true
    }
}

private struct RefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case refreshToken = "RefreshToken"
    }
}

// MARK: - Photos listing (Live Photo / video metadata)

/// One photo as returned by the direct `/drive/volumes/{volumeID}/photos` endpoint - carries the
/// `Tags` + `RelatedPhotos` that the SDK's `enumerateTimeline` wrapper drops.
struct PhotosListEntry: Decodable, Sendable {
    let linkID: String
    let captureTime: Double
    let tags: [Int]
    let relatedPhotos: [Related]

    struct Related: Decodable, Sendable {
        let linkID: String
        enum CodingKeys: String, CodingKey { case linkID = "LinkID" }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID"
        case captureTime = "CaptureTime"
        case tags = "Tags"
        case relatedPhotos = "RelatedPhotos"
    }

    /// Server-side PhotoTag: livePhotos = 3.
    var isLivePhoto: Bool { tags.contains(3) }
    /// The related files in listing order, newest first. `LivePhotoMotionLinks` chooses the motion of a Live Photo.
    var relatedLinkIDs: [String] { relatedPhotos.map(\.linkID) }
}

private struct PhotosListResponse: Decodable {
    let photos: [PhotosListEntry]
    enum CodingKeys: String, CodingKey { case photos = "Photos" }
}

struct VolumeEventPage: Decodable {
    struct Item: Decodable {
        let eventType: Int
        let linkID: String
        let contextShareID: String?
        let linkType: Int?
        let linkState: Int?

        private struct Link: Decodable {
            let linkID: String
            let type: Int?
            let state: Int?
            enum CodingKeys: String, CodingKey {
                case linkID = "LinkID"
                case type = "Type"
                case state = "State"
            }
        }

        enum CodingKeys: String, CodingKey {
            case eventType = "EventType"
            case link = "Link"
            case contextShareID = "ContextShareID"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            eventType = try values.decode(Int.self, forKey: .eventType)
            let link = try values.decode(Link.self, forKey: .link)
            linkID = link.linkID
            linkType = link.type
            linkState = link.state
            contextShareID = try values.decodeIfPresent(String.self, forKey: .contextShareID)
        }
    }

    let events: [Item]
    let eventID: String
    let hasMore: Bool
    let requiresRefresh: Bool

    enum CodingKeys: String, CodingKey {
        case events = "Events"
        case eventID = "EventID"
        case more = "More"
        case refresh = "Refresh"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        events = try values.decodeIfPresent([Item].self, forKey: .events) ?? []
        eventID = try values.decode(String.self, forKey: .eventID)
        hasMore = (try values.decodeIfPresent(Int.self, forKey: .more) ?? 0) != 0
        requiresRefresh = (try values.decodeIfPresent(Int.self, forKey: .refresh) ?? 0) != 0
    }
}

private struct LatestVolumeEventResponse: Decodable {
    let eventID: String
    enum CodingKeys: String, CodingKey { case eventID = "EventID" }
}

extension DriveSession {
    /// Fetches raw encrypted block bytes from storage for video streaming.
    /// A storage token uses a BareURL and the `pm-storage-token` header without session auth.
    /// A full URL receives session auth only on the trusted Drive API host; pre-signed storage URLs
    /// are fetched as-is so bearer tokens cannot leak cross-host.
    /// A dedicated storage session is used so the JSON `Accept` header isn't sent to the CDN.
    func fetchBlock(
        url: String,
        token: String?,
        priority: ProtonRequestPriority = ProtonRequestContext.priority,
        priorityHandle: ProtonRequestGovernor.PriorityHandle? = nil
    ) async throws -> Data {
        guard let u = URL(string: url), u.scheme == "https", u.host != nil else {
            throw ProtonAuthError.invalidResponse
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        if let token {
            req.setValue(token, forHTTPHeaderField: "pm-storage-token")
        } else if isTrustedAPIURL(u) {
            for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        }
        let permit = try await requestGovernor.acquire(
            scope: .storageDownload, priority: priority, priorityHandle: priorityHandle)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await storageSession.data(for: req)
        } catch {
            await requestGovernor.finish(permit, statusCode: nil)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            await requestGovernor.finish(permit, statusCode: nil)
            throw ProtonAuthError.invalidResponse
        }
        await requestGovernor.finish(
            permit,
            statusCode: http.statusCode,
            retryAfter: ProtonRetryAfter.seconds(from: http)
        )
        guard (200...299).contains(http.statusCode) else {
            throw ProtonAuthError.apiError(code: http.statusCode, message: "block fetch HTTP \(http.statusCode)")
        }
        return data
    }

    private func isTrustedAPIURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
            let host = url.host?.lowercased(),
            let expected = config.baseURL.host?.lowercased()
        else { return false }
        return host == expected
    }

    /// Enumerates the photos listing for a volume via the direct REST endpoint (cursor pagination),
    /// returning the per-photo `Tags` + `RelatedPhotos` the SDK wrapper omits. Pass `tag` for a
    /// server-side smart filter (Favorites/Videos/Selfies/…) - the API filters by a single tag.
    func fetchPhotosList(volumeID: String, tag: Int? = nil, pageSize: Int = 500) async throws -> [PhotosListEntry] {
        var all: [PhotosListEntry] = []
        try await forEachPhotosListPage(volumeID: volumeID, tag: tag, pageSize: pageSize) { page in
            all.append(contentsOf: page)
        }
        return all
    }

    /// Streams one decoded page at a time. Callers that need a complete list can use
    /// `fetchPhotosList`; index builders should use this seam to keep remote catalog rows out of
    /// memory while retaining the same cursor and cancellation contract.
    ///
    /// Pagination integrity: a full page whose last link repeats an already-used cursor is a
    /// repeating cursor (a direct repeat or a cycle like A-B-A). That loop cannot reach completion,
    /// so it must fail with `DrivePaginationError.repeatedPhotosCursor` instead of fetching the
    /// same pages forever or silently returning an incomplete list as a confirmed inventory.
    func forEachPhotosListPage(
        volumeID: String,
        tag: Int? = nil,
        pageSize: Int = 500,
        onPage: @escaping ([PhotosListEntry]) async throws -> Void
    ) async throws {
        guard pageSize > 0 else { throw DrivePaginationError.invalidPageSize(pageSize) }
        var usedCursors = Set<String>()
        var cursor: String?
        while true {
            try Task.checkCancellation()
            var path = "/drive/volumes/\(volumeID)/photos?PageSize=\(pageSize)"
            if let tag { path += "&Tag=\(tag)" }
            if let cursor { path += "&PreviousPageLastLinkID=\(cursor)" }
            let page = try await getJSON(path, as: PhotosListResponse.self)
            try Task.checkCancellation()
            guard page.photos.count == pageSize, let last = page.photos.last?.linkID else {
                try await onPage(page.photos)  // partial or empty terminal page
                return
            }
            // Full page: compute the follow cursor and check novelty before delivering the page,
            // so a repeating cursor never advances the scan or reaches onPage twice.
            guard usedCursors.insert(last).inserted else {
                throw DrivePaginationError.repeatedPhotosCursor(last)
            }
            try await onPage(page.photos)
            cursor = last
        }
    }

    func latestVolumeEventID(volumeID: String) async throws -> String {
        try await getJSON(
            "/drive/volumes/\(volumeID)/events/latest",
            as: LatestVolumeEventResponse.self
        ).eventID
    }

    func fetchVolumeEvents(volumeID: String, since eventID: String) async throws -> VolumeEventPage {
        try await getJSON(
            "/drive/volumes/\(volumeID)/events/\(eventID)",
            as: VolumeEventPage.self
        )
    }

    /// Sets an album's cover to an already-uploaded photo. A cleartext LinkID reference (no crypto) - matches the
    /// Proton web client: PUT the album link with the chosen photo's link id.
    func setAlbumCover(volumeID: String, albumLinkID: String, coverLinkID: String) async throws {
        try await send(
            "/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)", method: "PUT", body: ["CoverLinkID": coverLinkID]
        )
    }

    /// Permanently deletes the album container while preserving every photo in the timeline. Proton refuses
    /// this safe form when an album contains photos that exist nowhere else; callers must surface that failure
    /// instead of retrying with `DeleteAlbumPhotos=1`, which would permanently delete those originals.
    func deleteAlbum(volumeID: String, albumLinkID: String) async throws {
        try await send(
            "/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)?DeleteAlbumPhotos=0",
            method: "DELETE"
        )
    }

    /// The web client's `BATCH_REQUEST_SIZE` for link mutations - larger batches get per-item errors.
    private static let batchRequestSize = 50
    /// The web client's chunk size for `links/fetch_metadata`.
    private static let metadataBatchSize = 150

    /// Moves photos to trash (batch). Volume-keyed, on the `v2` path.
    ///
    /// This endpoint is a multistatus batch. It returns HTTP 200 with per-item result codes
    /// in `Responses[].Response`. A failed move must be detected from the body; ignoring it turns every
    /// failure into a silent "success" (photo gone from the grid, never in Recently Deleted).
    /// The state and the main photo of each link. A link that the server no longer knows is absent from the result.
    func fetchLinkVisibility(
        shareID: String, linkIDs: [String]
    ) async throws -> [String: TimelineRemoteVisibilityRequirement.Link] {
        var result: [String: TimelineRemoteVisibilityRequirement.Link] = [:]
        for chunk in Self.chunked(linkIDs, size: Self.metadataBatchSize) {
            try Task.checkCancellation()
            let data = try await send(
                "/drive/shares/\(shareID)/links/fetch_metadata", method: "POST", body: ["LinkIDs": chunk],
                retryOnRateLimit: true)
            for link in try JSONDecoder().decode(LinkVisibilityResponse.self, from: data).links {
                guard let id = link.linkID else { continue }
                result[id] = .init(
                    isActive: link.state == nil || link.state == 1,
                    mainPhotoLinkID: link.fileProperties?.activeRevision?.photo?.mainPhotoLinkID,
                    trashTime: link.trashed)
            }
        }
        return result
    }

    func trash(volumeID: String, linkIDs: [String]) async throws {
        try await batchLinkAction(
            "trash", volumeID: volumeID, linkIDs: linkIDs,
            path: "/drive/v2/volumes/\(volumeID)/trash_multiple", method: "POST")
    }

    /// Restores photos from trash (batch). Same multistatus contract as `trash`.
    func restore(volumeID: String, linkIDs: [String]) async throws {
        try await batchLinkAction(
            "restore", volumeID: volumeID, linkIDs: linkIDs,
            path: "/drive/v2/volumes/\(volumeID)/trash/restore_multiple", method: "PUT")
    }

    /// Runs one batched link mutation in web-client-sized chunks and decodes the per-item multistatus
    /// body, throwing `DriveBatchActionError` if any link failed so callers never mistake a failed or
    /// partial move for success. The error names the links worth another attempt: links without an unambiguous
    /// answer, and links whose request failed for a transient reason or was never sent.
    private func batchLinkAction(
        _ action: String, volumeID: String, linkIDs: [String], path: String, method: String
    ) async throws {
        guard !linkIDs.isEmpty else { return }
        var succeeded = 0
        var refused = 0
        var retryable = Set<String>()
        var firstError: String?
        let chunks = Self.chunked(linkIDs, size: Self.batchRequestSize)
        for (index, chunk) in chunks.enumerated() {
            let data: Data
            do {
                data = try await send(path, method: method, body: ["LinkIDs": chunk])
            } catch {
                // A single request keeps its own error for the caller. Otherwise every link settles on its own: a final
                // rejection refuses this request's links, and links of a transient failure or of unsent requests retry.
                guard chunks.count > 1 else { throw error }
                if DriveBatchActionError.isFinal(error) {
                    refused += chunk.count
                } else {
                    retryable.formUnion(chunk)
                }
                retryable.formUnion(chunks[(index + 1)...].joined())
                firstError = firstError ?? "request \(index + 1) of \(chunks.count) failed"
                break
            }
            let responses = (try? JSONDecoder().decode(BatchLinkResponses.self, from: data))?.responses ?? []
            let byLink = Dictionary(grouping: responses.filter { $0.linkID != nil }) { $0.linkID ?? "" }
            for linkID in chunk {
                // A missing or repeated answer is ambiguous; only one answer per link settles it.
                guard let answers = byLink[linkID], answers.count == 1, let status = answers[0].response else {
                    retryable.insert(linkID)
                    if firstError == nil { firstError = "missing or ambiguous item status" }
                    continue
                }
                if let error = status.error, !error.isEmpty {
                    refused += 1
                    if firstError == nil { firstError = error }
                } else if let code = status.code {
                    if code == 1000 {
                        succeeded += 1
                    } else {
                        refused += 1
                        if firstError == nil { firstError = "unsuccessful item status \(code)" }
                    }
                } else {
                    retryable.insert(linkID)
                    if firstError == nil { firstError = "missing item status" }
                }
            }
        }
        let failed = refused + retryable.count
        DebugLog.log(
            "\(action): vol=\(volumeID.prefix(8))… n=\(linkIDs.count) ok=\(succeeded) failed=\(failed)"
                + (firstError.map { " firstError=\($0)" } ?? ""))
        if failed > 0 {
            throw DriveBatchActionError(failed: failed, retryableLinkIDs: retryable, total: linkIDs.count)
        }
    }

    /// Lists trashed links. The trash endpoint returns only share and link IDs. Fetch metadata with
    /// the link endpoint before constructing the result.
    ///
    /// Pagination integrity: a full page that contributes zero new (shareID, linkID) identities is
    /// an infinite loop signal; it must fail with `DrivePaginationError.trashPageWithoutNewIDs`
    /// instead of repeating forever or returning an incomplete list.
    func listTrash(volumeID: String, pageSize: Int = 150) async throws -> [TrashLink] {
        guard pageSize > 0 else { throw DrivePaginationError.invalidPageSize(pageSize) }
        var idsByShare: [String: [String]] = [:]
        var seenByShare: [String: Set<String>] = [:]
        var pageIndex = 0
        while true {
            try Task.checkCancellation()
            let r = try await getJSON(
                "/drive/volumes/\(volumeID)/trash?Page=\(pageIndex)&PageSize=\(pageSize)", as: VolumeTrashResponse.self)
            try Task.checkCancellation()
            var rawCount = 0
            var newCount = 0
            for group in r.trash ?? [] {
                rawCount += group.linkIDs.count
                let key = group.shareID
                let newIds = group.linkIDs.filter { seenByShare[key, default: []].insert($0).inserted }
                if !newIds.isEmpty {
                    idsByShare[key, default: []].append(contentsOf: newIds)
                    newCount += newIds.count
                }
            }
            if rawCount < pageSize { break }  // terminal page (server returned less than a full page)
            if rawCount >= pageSize && newCount == 0 {
                throw DrivePaginationError.trashPageWithoutNewIDs(pageIndex)
            }
            pageIndex += 1
        }
        var all: [TrashLink] = []
        for (shareID, ids) in idsByShare {
            for chunk in Self.chunked(ids, size: Self.metadataBatchSize) {
                try Task.checkCancellation()
                let data = try await send(
                    "/drive/shares/\(shareID)/links/fetch_metadata",
                    method: "POST",
                    body: ["LinkIDs": chunk],
                    retryOnRateLimit: true
                )
                let decoded = try JSONDecoder().decode(LinkMetaBatchResponse.self, from: data)
                all.append(contentsOf: decoded.links ?? [])
            }
        }
        try Task.checkCancellation()
        let totalIDs = seenByShare.values.reduce(0) { $0 + $1.count }
        DebugLog.log("listTrash: vol=\(volumeID.prefix(8))… trashedIDs=\(totalIDs) resolved=\(all.count)")
        return all
    }

    private static func chunked(_ items: [String], size: Int) -> [[String]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Lists the photos contained in an album (same per-photo shape as the timeline).
    func fetchAlbumPhotos(volumeID: String, albumLinkID: String) async throws -> [PhotosListEntry] {
        var all: [PhotosListEntry] = []
        var anchor: String?
        repeat {
            var path = "/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)/children?Desc=1"
            if let anchor { path += "&AnchorID=\(anchor)" }
            let page = try await getJSON(path, as: AlbumPhotosResponse.self)
            all.append(contentsOf: page.photos)
            anchor = page.more == true ? page.anchorID : nil
        } while anchor != nil
        return all
    }
}

/// One trashed link as resolved via `links/fetch_metadata`. Listing fields are optional because the endpoint
/// can omit fields per item; the bridge filters incomplete entries.
struct TrashLink: Decodable {
    let linkID: String?
    /// LinkType: 1 = folder, 2 = file, 3 = album.
    let type: Int?
    let createTime: Double?
    let mimeType: String?
    let fileProperties: FileProps?
    struct FileProps: Decodable {
        let activeRevision: Revision?
        struct Revision: Decodable {
            let photo: Photo?
            struct Photo: Decodable {
                let captureTime: Double?
                let mainPhotoLinkID: String?
                enum CodingKeys: String, CodingKey {
                    case captureTime = "CaptureTime"
                    case mainPhotoLinkID = "MainPhotoLinkID"
                }
            }
            enum CodingKeys: String, CodingKey { case photo = "Photo" }
        }
        enum CodingKeys: String, CodingKey { case activeRevision = "ActiveRevision" }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID"
        case type = "Type"
        case createTime = "CreateTime"
        case
            mimeType = "MIMEType"
        case fileProperties = "FileProperties"
    }
    var captureTime: Double { fileProperties?.activeRevision?.photo?.captureTime ?? createTime ?? 0 }
    /// Non-nil when this link is a Live Photo's paired video - hidden from the trash grid, exactly like
    /// the timeline listing hides RelatedPhotos behind their main photo.
    var mainPhotoLinkID: String? { fileProperties?.activeRevision?.photo?.mainPhotoLinkID }
}

/// `GET /drive/volumes/{id}/trash` - id groups only, no link bodies.
private struct VolumeTrashResponse: Decodable {
    let trash: [Group]?
    struct Group: Decodable {
        let shareID: String
        let linkIDs: [String]
        enum CodingKeys: String, CodingKey {
            case shareID = "ShareID"
            case linkIDs = "LinkIDs"
        }
    }
    enum CodingKeys: String, CodingKey { case trash = "Trash" }
}

/// `POST /drive/shares/{shareID}/links/fetch_metadata` response.
/// `links/fetch_metadata` fields that decide whether a photos listing can show a link.
private struct LinkVisibilityResponse: Decodable {
    /// Required: a response without it is incomplete, not a list of deleted links.
    let links: [Body]
    struct Body: Decodable {
        let linkID: String?
        let state: Int?
        let fileProperties: TrashLink.FileProps?
        let trashed: Int64?
        enum CodingKeys: String, CodingKey {
            case linkID = "LinkID"
            case state = "State"
            case fileProperties = "FileProperties"
            case trashed = "Trashed"
        }
    }
    enum CodingKeys: String, CodingKey { case links = "Links" }
}

private struct LinkMetaBatchResponse: Decodable {
    let links: [TrashLink]?
    enum CodingKeys: String, CodingKey { case links = "Links" }
}

/// Per-item multistatus body of `trash_multiple` / `restore_multiple` (HTTP 200 even when items fail).
private struct BatchLinkResponses: Decodable {
    let responses: [Item]?
    struct Item: Decodable {
        let linkID: String?
        let response: Status?
        struct Status: Decodable {
            let code: Int?
            let error: String?
            enum CodingKeys: String, CodingKey {
                case code = "Code"
                case error = "Error"
            }
        }
        enum CodingKeys: String, CodingKey {
            case linkID = "LinkID"
            case response = "Response"
        }
    }
    enum CodingKeys: String, CodingKey { case responses = "Responses" }
}

/// A batched link mutation partially or fully failed (per-item multistatus codes).
struct DriveBatchActionError: LocalizedError {
    let failed: Int
    /// Failed links without an unambiguous answer, and links of a request that failed for a transient reason or was
    /// never sent. Proton may still apply the change, so only these are worth another attempt; the other failed
    /// links were refused.
    let retryableLinkIDs: Set<String>
    let total: Int

    /// Proton refused the request itself (a 4xx answer other than 408 and 429); repeating it cannot succeed.
    static func isFinal(_ error: any Error) -> Bool {
        guard case .apiError(let code, _)? = error as? ProtonAuthError else { return false }
        return (400...499).contains(code) && code != 408 && code != 429
    }
    var errorDescription: String? {
        L10n.string("error.batch_action_incomplete \(failed) \(total)")
    }
}

/// A paginated Drive listing made no forward progress (invalid page size or a repeating
/// page cursor), so the scan cannot reach completion. Failing beats silently looping forever
/// or reporting an incomplete result as a confirmed-complete inventory.
struct DrivePaginationError: LocalizedError, Equatable {
    let reason: Reason
    enum Reason: Equatable {
        /// The requested page size is not a positive integer.
        case invalidPageSize(Int)
        /// A photos listing full page reused an already-seen cursor (direct repeat or a cycle).
        case repeatedPhotosCursor(String)
        /// A trash listing returned a full page that contained no new (shareID, linkID) identities.
        case trashPageWithoutNewIDs(pageIndex: Int)
    }
    static func invalidPageSize(_ pageSize: Int) -> DrivePaginationError {
        DrivePaginationError(reason: .invalidPageSize(pageSize))
    }
    static func repeatedPhotosCursor(_ cursor: String) -> DrivePaginationError {
        DrivePaginationError(reason: .repeatedPhotosCursor(cursor))
    }
    static func trashPageWithoutNewIDs(_ pageIndex: Int) -> DrivePaginationError {
        DrivePaginationError(reason: .trashPageWithoutNewIDs(pageIndex: pageIndex))
    }
    var errorDescription: String? {
        switch reason {
        case .invalidPageSize(let pageSize):
            return "Drive pagination requires a positive page size (got \(pageSize))."
        case .repeatedPhotosCursor:
            return "Drive photos listing did not advance. Please try again."
        case .trashPageWithoutNewIDs(let pageIndex):
            return
                "Drive trash listing page \(pageIndex) returned a full page with no new link identities; aborting to avoid an infinite pagination loop."
        }
    }
}

private struct AlbumPhotosResponse: Decodable {
    let photos: [PhotosListEntry]
    let anchorID: String?
    let more: Bool?
    enum CodingKeys: String, CodingKey {
        case photos = "Photos"
        case anchorID = "AnchorID"
        case more = "More"
    }
}

// MARK: - Account data (users / addresses)

struct AccountData {
    let userKeys: [Key]
    let addresses: [Address]
    let accountInfo: DriveAccountInfoSnapshot
}

struct DriveStorageQuota: Equatable, Sendable {
    let usedBytes: Int64
    let maxBytes: Int64
}

struct DriveAccountInfoSnapshot: Equatable, Sendable {
    let quota: DriveStorageQuota?
    let primaryEmail: String?
}

extension DriveSession {
    /// Fetches the user's keys and addresses needed to build the SDK `AccountClient`.
    /// We decode minimal DTOs (ProtonCore's own `Codable` is stricter than the live API) and
    /// construct `ProtonCoreDataModel.Key`/`Address` via their public initialisers.
    func fetchAccountData() async throws -> AccountData {
        async let usersData = authedData(path: "/core/v4/users", method: "GET", retryOn429: true)
        async let addressesData = authedData(path: "/core/v4/addresses", method: "GET", retryOn429: true)
        let (uData, aData) = try await (usersData, addressesData)
        // Persist (encrypted) so a later offline cold start can rebuild the crypto without the network.
        AccountDataCache.save(
            users: uData, addresses: aData, uid: current.uid, keyPassword: current.keyPassword,
            in: accountCacheDirectory)
        let account = try Self.decodeAccountData(users: uData, addresses: aData)
        await publishAccountInfo(account.accountInfo)
        return account
    }

    /// The encrypted-on-disk account data from a previous online launch, or nil if absent/undecryptable. Lets
    /// `DriveSDKBridge.init` rebuild the (pure) Drive crypto + SDK account client when the network is unavailable.
    func cachedAccountData() async -> AccountData? {
        guard
            let blob = AccountDataCache.load(
                uid: current.uid, keyPassword: current.keyPassword, in: accountCacheDirectory)
        else { return nil }
        guard let account = try? Self.decodeAccountData(users: blob.users, addresses: blob.addresses) else {
            return nil
        }
        await publishAccountInfo(account.accountInfo)
        return account
    }

    private static func decodeAccountData(users: Data, addresses: Data) throws -> AccountData {
        let u = try JSONDecoder().decode(UsersResponse.self, from: users)
        let a = try JSONDecoder().decode(AddressesResponse.self, from: addresses)
        // The primary address is the lowest-ordered one (Proton lists the account's main address first).
        let primaryEmail = a.addresses.min(by: { ($0.order ?? 0) < ($1.order ?? 0) })?.email
        return AccountData(
            userKeys: u.user.keys.map(makeKey),
            addresses: a.addresses.map(makeAddress),
            accountInfo: DriveAccountInfoSnapshot(
                quota: driveStorageQuota(from: u.user),
                primaryEmail: primaryEmail
            )
        )
    }

    private func publishAccountInfo(_ snapshot: DriveAccountInfoSnapshot) async {
        let accountUID = current.uid
        await MainActor.run {
            if let quota = snapshot.quota, quota.maxBytes > 0 {
                AccountInfo.shared.updateDriveStorage(
                    usedBytes: quota.usedBytes,
                    maxBytes: quota.maxBytes,
                    accountUID: accountUID
                )
            }
            AccountInfo.shared.update(primaryEmail: snapshot.primaryEmail, accountUID: accountUID)
        }
    }

    static func decodeDriveStorageQuota(users: Data) throws -> DriveStorageQuota? {
        driveStorageQuota(from: try JSONDecoder().decode(UsersResponse.self, from: users).user)
    }

    private static func driveStorageQuota(from user: UsersResponse.UserBody) -> DriveStorageQuota? {
        // MaxBaseSpace marks accounts with separate Drive and base-storage allocations.
        if user.maxBaseSpace != nil {
            guard let max = user.maxDriveSpace ?? user.maxSpace else { return nil }
            return DriveStorageQuota(usedBytes: user.usedDriveSpace ?? 0, maxBytes: max)
        }
        guard let used = user.usedSpace, let max = user.maxSpace else { return nil }
        return DriveStorageQuota(usedBytes: used, maxBytes: max)
    }

    private static func makeKey(_ d: CoreKeyDTO) -> Key {
        Key(
            keyID: d.id, privateKey: d.privateKey, keyFlags: d.flags ?? 0,
            token: d.token, signature: d.signature, activation: nil,
            active: d.active ?? 1, version: d.version ?? 0, primary: d.primary ?? 0)
    }

    private static func makeAddress(_ d: CoreAddressDTO) -> Address {
        Address(
            addressID: d.id, domainID: d.domainID, email: d.email,
            send: Address.AddressSendReceive(rawValue: d.send ?? 1) ?? .active,
            receive: Address.AddressSendReceive(rawValue: d.receive ?? 1) ?? .active,
            status: Address.AddressStatus(rawValue: d.status ?? 1) ?? .enabled,
            type: Address.AddressType(rawValue: d.type ?? 1) ?? .protonDomain,
            order: d.order ?? 0, displayName: d.displayName ?? "", signature: d.signature ?? "",
            hasKeys: d.hasKeys ?? (d.keys.isEmpty ? 0 : 1), keys: d.keys.map(makeKey)
        )
    }
}

private struct UsersResponse: Decodable {
    let user: UserBody
    enum CodingKeys: String, CodingKey { case user = "User" }
    struct UserBody: Decodable {
        let keys: [CoreKeyDTO]
        let usedSpace: Int64?
        let maxSpace: Int64?
        let usedDriveSpace: Int64?
        let maxDriveSpace: Int64?
        let usedBaseSpace: Int64?
        let maxBaseSpace: Int64?
        enum CodingKeys: String, CodingKey {
            case keys = "Keys"
            case usedSpace = "UsedSpace"
            case maxSpace = "MaxSpace"
            case usedDriveSpace = "UsedDriveSpace"
            case maxDriveSpace = "MaxDriveSpace"
            case usedBaseSpace = "UsedBaseSpace"
            case maxBaseSpace = "MaxBaseSpace"
        }
    }
}

private struct AddressesResponse: Decodable {
    let addresses: [CoreAddressDTO]
    enum CodingKeys: String, CodingKey { case addresses = "Addresses" }
}

private struct CoreKeyDTO: Decodable {
    let id: String
    let privateKey: String
    let token: String?
    let signature: String?
    let primary: Int?
    let active: Int?
    let flags: Int?
    let version: Int?
    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case privateKey = "PrivateKey"
        case token = "Token"
        case signature = "Signature"
        case primary = "Primary"
        case active = "Active"
        case flags = "Flags"
        case version = "Version"
    }
}

private struct CoreAddressDTO: Decodable {
    let id: String
    let domainID: String?
    let email: String
    let send: Int?
    let receive: Int?
    let status: Int?
    let type: Int?
    let order: Int?
    let displayName: String?
    let signature: String?
    let hasKeys: Int?
    let keys: [CoreKeyDTO]
    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case domainID = "DomainID"
        case email = "Email"
        case send = "Send"
        case receive = "Receive"
        case status = "Status"
        case type = "Type"
        case order = "Order"
        case displayName = "DisplayName"
        case signature = "Signature"
        case hasKeys = "HasKeys"
        case keys = "Keys"
    }
}
