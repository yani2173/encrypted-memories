import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend

/// URLProtocol stub for `DriveSession`'s test seam: serves canned JSON per (method, path) and records
/// every request (method, path+query, body) for assertions. State is static because URLSession
/// instantiates the protocol itself - each test resets it via `reset()`.
final class StubURLProtocol: URLProtocol {
    struct Recorded: Sendable {
        let method: String
        let path: String  // path + query
        let body: Data?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [(status: Int, body: String)]] = [:]
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var hanging: Set<String> = []

    static func reset() {
        lock.withLock {
            routes = [:]
            recorded = []
            hanging = []
        }
    }

    /// Register "method /path" as a request that never answers until its task is cancelled.
    static func hang(_ methodAndPath: String) {
        lock.withLock { _ = hanging.insert(methodAndPath) }
    }

    /// Register a canned response for "method /path" (path without query - matching ignores the query).
    static func route(_ methodAndPath: String, status: Int = 200, json: String) {
        lock.withLock { routes[methodAndPath] = [(status, json)] }
    }

    /// Register ordered responses for retry tests. The final response remains reusable if the caller
    /// unexpectedly issues another request, matching `route`'s existing repeatable behavior.
    static func routeSequence(_ methodAndPath: String, responses: [(status: Int, json: String)]) {
        lock.withLock { routes[methodAndPath] = responses.map { ($0.status, $0.json) } }
    }

    static func requests() -> [Recorded] {
        lock.withLock { recorded }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let pathAndQuery = url.path + (url.query.map { "?\($0)" } ?? "")
        let body = Self.drainBody(of: request)
        Self.lock.withLock {
            Self.recorded.append(Recorded(method: method, path: pathAndQuery, body: body))
        }
        guard !Self.lock.withLock({ Self.hanging.contains("\(method) \(url.path)") }) else { return }
        let match = Self.lock.withLock { () -> (status: Int, body: String)? in
            let key = "\(method) \(url.path)"
            guard var responses = Self.routes[key], let first = responses.first else { return nil }
            if responses.count > 1 {
                responses.removeFirst()
                Self.routes[key] = responses
            }
            return first
        }
        let (status, payload) = match ?? (404, #"{"Code":404,"Error":"no stub route"}"#)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession exposes POST bodies to URLProtocol as a stream, not `httpBody`.
    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func makeSession() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-session-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}

private func linkIDs(inBodyOf request: StubURLProtocol.Recorded) throws -> [String] {
    let body = try #require(request.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(json["LinkIDs"] as? [String])
}

/// Serialized parent for every suite that touches the process-global `StubURLProtocol` - sibling
/// suites otherwise run in parallel and clobber each other's route tables. Nest new stub-based
/// suites here (see `PhotoDuplicatesEndpointTests`).
@Suite(.serialized) enum DriveSessionStubSuite {}

extension DriveSessionStubSuite {
    /// These tests are serialized because the URLProtocol stub's route table is process-global.
    @Suite struct DriveSessionTrashTests {
        @Test func trashPostsLinkIDsToV2VolumeTrashMultiple() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "POST /drive/v2/volumes/vol1/trash_multiple",
                json: #"""
                    {"Code":1001,"Responses":[
                        {"LinkID":"l1","Response":{"Code":1000}},
                        {"LinkID":"l2","Response":{"Code":1000}}
                    ]}
                    """#)

            try await makeSession().trash(volumeID: "vol1", linkIDs: ["l1", "l2"])

            let requests = StubURLProtocol.requests()
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.method == "POST")
            #expect(request.path == "/drive/v2/volumes/vol1/trash_multiple")
            #expect(try linkIDs(inBodyOf: request) == ["l1", "l2"])
        }

        @Test func trashThrowsWhenAnyItemFailsInTheMultistatusBody() async throws {
            // The API can return HTTP 200 with item failures in the body. Surface those failures.
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "POST /drive/v2/volumes/vol1/trash_multiple",
                json: #"""
                    {"Code":1001,"Responses":[
                        {"LinkID":"ok","Response":{"Code":1000}},
                        {"LinkID":"bad","Response":{"Code":2501,"Error":"Insufficient permissions"}}
                    ]}
                    """#)

            let error = await #expect(throws: DriveBatchActionError.self) {
                try await makeSession().trash(volumeID: "vol1", linkIDs: ["ok", "bad"])
            }
            #expect(error?.failed == 1)
            #expect(error?.retryableLinkIDs.isEmpty == true, "Proton refused the link; a retry cannot change that")
        }

        @Test(arguments: [
            #"{"Code":1000}"#,
            #"{"Code":1001,"Responses":[]}"#,
            #"{"Code":1001,"Responses":[{"LinkID":"l1","Response":{"Code":1000}}]}"#,
            #"{"Code":1001,"Responses":[{"LinkID":"l1","Response":{"Code":1000}},{"LinkID":"l1","Response":{"Code":1000}}]}"#,
            #"{"Code":1001,"Responses":[{"LinkID":"l1","Response":{"Code":1000}},{"LinkID":"other","Response":{"Code":1000}}]}"#,
            #"{"Code":1001,"Responses":[{"LinkID":"l1","Response":{}},{"LinkID":"l2","Response":{"Code":1000}}]}"#,
            #"{"Code":1001,"Responses":[{"LinkID":"l1"},{"LinkID":"l2","Response":{"Code":1000}}]}"#,
        ])
        func incompleteMultistatusNeverConfirmsTrashOrRestore(_ response: String) async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/v2/volumes/vol1/trash_multiple", json: response)
            StubURLProtocol.route("PUT /drive/v2/volumes/vol1/trash/restore_multiple", json: response)
            let session = makeSession()

            let trashError = await #expect(throws: DriveBatchActionError.self) {
                try await session.trash(volumeID: "vol1", linkIDs: ["l1", "l2"])
            }
            let restoreError = await #expect(throws: DriveBatchActionError.self) {
                try await session.restore(volumeID: "vol1", linkIDs: ["l1", "l2"])
            }
            #expect(trashError?.retryableLinkIDs.isEmpty == false, "an unanswered link is worth another attempt")
            #expect(restoreError?.retryableLinkIDs.isEmpty == false, "an unanswered link is worth another attempt")
        }

        @Test func aFailedLaterRequestKeepsEveryUnansweredAndUnsentLinkRetryable() async throws {
            StubURLProtocol.reset()
            let links = (0..<60).map { "l\($0)" }
            // The first 50 links get no per-item answer; the request for the last 10 fails for a transient reason.
            StubURLProtocol.routeSequence(
                "PUT /drive/v2/volumes/vol1/trash/restore_multiple",
                responses: [
                    (status: 200, json: #"{"Code":1001,"Responses":[]}"#),
                    (status: 503, json: #"{"Code":503,"Error":"unavailable"}"#),
                ])

            let error = await #expect(throws: DriveBatchActionError.self) {
                try await makeSession().restore(volumeID: "vol1", linkIDs: links)
            }
            #expect(error?.retryableLinkIDs == Set(links))
            #expect(StubURLProtocol.requests().count == 2)
        }

        @Test func aFailedLaterRequestSettlesTheLinksThatProtonAlreadyConfirmed() async throws {
            StubURLProtocol.reset()
            let links = (0..<60).map { "l\($0)" }
            let answers = links.prefix(50).map { #"{"LinkID":"\#($0)","Response":{"Code":1000}}"# }
            StubURLProtocol.routeSequence(
                "PUT /drive/v2/volumes/vol1/trash/restore_multiple",
                responses: [
                    (status: 200, json: #"{"Code":1001,"Responses":["# + answers.joined(separator: ",") + "]}"),
                    (status: 503, json: #"{"Code":503,"Error":"unavailable"}"#),
                ])

            let error = await #expect(throws: DriveBatchActionError.self) {
                try await makeSession().restore(volumeID: "vol1", linkIDs: links)
            }
            #expect(error?.retryableLinkIDs == Set(links.suffix(10)))
        }

        @Test func aRejectedFirstRequestRetriesTheLinksOfLaterRequests() async throws {
            StubURLProtocol.reset()
            let links = (0..<120).map { "l\($0)" }
            StubURLProtocol.routeSequence(
                "PUT /drive/v2/volumes/vol1/trash/restore_multiple",
                responses: [(status: 422, json: #"{"Code":2011,"Error":"refused"}"#)])

            let error = await #expect(throws: DriveBatchActionError.self) {
                try await makeSession().restore(volumeID: "vol1", linkIDs: links)
            }
            #expect(error?.retryableLinkIDs == Set(links.dropFirst(50)), "unsent links have no outcome yet")
            #expect(error?.failed == 120)
            #expect(StubURLProtocol.requests().count == 1)
        }

        @Test func aPartialAnswerSettlesItsConfirmedLinksAndRetriesTheRest() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "PUT /drive/v2/volumes/vol1/trash/restore_multiple",
                json: #"""
                    {"Code":1001,"Responses":[
                        {"LinkID":"confirmed","Response":{"Code":1000}},
                        {"LinkID":"refused","Response":{"Code":2501,"Error":"Not in trash"}},
                        {"LinkID":"twice","Response":{"Code":1000}},
                        {"LinkID":"twice","Response":{"Code":1000}}
                    ]}
                    """#)

            let error = await #expect(throws: DriveBatchActionError.self) {
                try await makeSession().restore(
                    volumeID: "vol1", linkIDs: ["confirmed", "refused", "twice", "missing"])
            }
            #expect(error?.retryableLinkIDs == ["twice", "missing"])
            #expect(error?.failed == 3)
        }

        @Test func pendingEffectsRetryOnlyPhotosThatProtonDidNotAnswer() async {
            let answered = PhotoUID(volumeID: "vol1", nodeID: "answered")
            let refused = PhotoUID(volumeID: "vol1", nodeID: "refused")
            let unanswered = PhotoUID(volumeID: "vol1", nodeID: "unanswered")

            let batch = await ProtonPendingRemoteEffects.runBatch([answered, refused, unanswered]) {
                throw DriveBatchActionError(failed: 2, retryableLinkIDs: ["unanswered"], total: 3)
            }
            let allRefused = await ProtonPendingRemoteEffects.run {
                throw DriveBatchActionError(failed: 1, retryableLinkIDs: [], total: 1)
            }
            let transport = await ProtonPendingRemoteEffects.runBatch([answered, refused]) {
                throw URLError(.timedOut)
            }

            #expect(batch == PendingBatchEffectResult(retry: [unanswered]))
            #expect(allRefused == .permanentFailure)
            #expect(transport == .retrying([answered, refused]))
        }

        @Test func restorePutsLinkIDsToRestoreMultiple() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "PUT /drive/v2/volumes/vol1/trash/restore_multiple",
                json: #"""
                    {"Code":1001,"Responses":[{"LinkID":"l1","Response":{"Code":1000}}]}
                    """#)

            try await makeSession().restore(volumeID: "vol1", linkIDs: ["l1"])

            let request = try #require(StubURLProtocol.requests().first)
            #expect(request.method == "PUT")
            #expect(request.path == "/drive/v2/volumes/vol1/trash/restore_multiple")
            #expect(try linkIDs(inBodyOf: request) == ["l1"])
        }

        @Test func deleteAlbumUsesSafeAlbumEndpointWithoutDeletingAlbumOnlyPhotos() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("DELETE /drive/photos/volumes/vol1/albums/album1", json: #"{"Code":1000}"#)

            try await makeSession().deleteAlbum(volumeID: "vol1", albumLinkID: "album1")

            let request = try #require(StubURLProtocol.requests().first)
            #expect(request.method == "DELETE")
            #expect(request.path == "/drive/photos/volumes/vol1/albums/album1?DeleteAlbumPhotos=0")
            #expect(request.body == nil)
        }

        @Test func listTrashResolvesIdGroupsViaFetchMetadata() async throws {
            // The volume trash listing returns only {ShareID, LinkIDs} groups. Decoding `Links` from it
            // yields nil, so the bridge must fetch link bodies with
            // the per-share fetch_metadata batch.
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/trash",
                json: #"""
                    {"Code":1000,"Trash":[
                        {"ShareID":"share1","LinkIDs":["photo1","video-of-live","album1"],"ParentIDs":["root"]}
                    ]}
                    """#)
            // Realistic LinkMeta bodies: a still photo (capture time on the revision), a Live Photo's paired
            // video (MainPhotoLinkID set), and a trashed album (Type 3).
            StubURLProtocol.route(
                "POST /drive/shares/share1/links/fetch_metadata",
                json: #"""
                    {"Code":1000,"Links":[
                        {"LinkID":"photo1","ParentLinkID":"root","Type":2,"Name":"x","MIMEType":"image/heic",
                         "CreateTime":1700000000,"Size":123,
                         "FileProperties":{"ContentKeyPacket":"ckp","ActiveRevision":{"ID":"rev1",
                            "Photo":{"LinkID":"photo1","CaptureTime":1600000000,"MainPhotoLinkID":null,
                                     "RelatedPhotosLinkIDs":["video-of-live"],"Exif":null}}},
                         "PhotoProperties":{"Albums":[],"Tags":[3]}},
                        {"LinkID":"video-of-live","ParentLinkID":"root","Type":2,"MIMEType":"video/quicktime",
                         "CreateTime":1700000001,
                         "FileProperties":{"ContentKeyPacket":"ckp","ActiveRevision":{"ID":"rev2",
                            "Photo":{"LinkID":"video-of-live","CaptureTime":1600000000,"MainPhotoLinkID":"photo1"}}}},
                        {"LinkID":"album1","Type":3,"Name":"y"}
                    ]}
                    """#)

            let links = try await makeSession().listTrash(volumeID: "vol1")

            #expect(links.count == 3)
            let photo = try #require(links.first { $0.linkID == "photo1" })
            #expect(photo.type == 2)
            #expect(photo.mimeType == "image/heic")
            #expect(photo.captureTime == 1_600_000_000)  // revision Photo.CaptureTime, not CreateTime
            #expect(photo.mainPhotoLinkID == nil)
            let liveVideo = try #require(links.first { $0.linkID == "video-of-live" })
            #expect(liveVideo.mainPhotoLinkID == "photo1")  // lets the bridge hide it, like the timeline
            let album = try #require(links.first { $0.linkID == "album1" })
            #expect(album.type == 3)
            #expect(album.captureTime == 0)  // tolerant: no CreateTime, no crash

            let paths = StubURLProtocol.requests().map(\.path)
            #expect(paths.first?.hasPrefix("/drive/volumes/vol1/trash?Page=0") == true)
            #expect(paths.contains("/drive/shares/share1/links/fetch_metadata"))
        }

        @Test func linkVisibilityReadsTheStateAndTheMainPhoto() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "POST /drive/shares/share1/links/fetch_metadata",
                json: #"""
                    {"Code":1000,"Links":[
                        {"LinkID":"trashed-edit","Type":2,"State":2,"Trashed":1790000000,
                         "FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":null}}}},
                        {"LinkID":"original","Type":2,"State":1,"Trashed":null,
                         "FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"trashed-edit"}}}}
                    ]}
                    """#)

            let links = try await makeSession().fetchLinkVisibility(
                shareID: "share1", linkIDs: ["trashed-edit", "original", "deleted"])

            #expect(links["trashed-edit"] == .init(isActive: false, mainPhotoLinkID: nil, trashTime: 1_790_000_000))
            #expect(links["original"] == .init(isActive: true, mainPhotoLinkID: "trashed-edit"))
            #expect(links["deleted"] == nil, "a link that the server no longer knows is absent")
        }

        @Test func linkVisibilityRejectsAResponseWithoutLinks() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/shares/share1/links/fetch_metadata", json: #"{"Code":1000}"#)

            await #expect(throws: (any Error).self) {
                try await makeSession().fetchLinkVisibility(shareID: "share1", linkIDs: ["photo"])
            }
        }

        @Test func listTrashEmptyVolumeYieldsNoLinksAndNoMetadataCall() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/volumes/vol1/trash", json: #"{"Code":1000,"Trash":[]}"#)

            let links = try await makeSession().listTrash(volumeID: "vol1")

            #expect(links.isEmpty)
            #expect(StubURLProtocol.requests().count == 1, "no fetch_metadata call for an empty trash")
        }

        @Test func listTrashInvalidPageSizeZeroThrowsWithoutNetwork() async throws {
            StubURLProtocol.reset()
            await #expect(throws: DrivePaginationError.self) {
                try await makeSession().listTrash(volumeID: "vol1", pageSize: 0)
            }
            #expect(StubURLProtocol.requests().isEmpty, "no network call for invalid pageSize")
        }

        @Test func listTrashRepeatedFullPageThrowsTypedError() async throws {
            // Two identical full pages contribute zero new (shareID, linkID) identities: typed error.
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/trash",
                responses: [
                    (status: 200, json: #"{"Code":1000,"Trash":[{"ShareID":"s1","LinkIDs":["a","b"]}]}"#),
                    (status: 200, json: #"{"Code":1000,"Trash":[{"ShareID":"s1","LinkIDs":["a","b"]}]}"#),
                    // Safety valve: with the fix the call throws on page 2; without it, this terminates the loop.
                    (status: 200, json: #"{"Code":1000,"Trash":[]}"#),
                ]
            )

            await #expect(throws: DrivePaginationError.trashPageWithoutNewIDs(1)) {
                try await makeSession().listTrash(volumeID: "vol1", pageSize: 2)
            }
            #expect(StubURLProtocol.requests().count == 2, "fails on the second page, after the first")
        }

        @Test func listTrashOverlappingFullPageWithNewIDsSucceedsAndDedupes() async throws {
            // A full page that overlaps the previous page but adds new identities must succeed. The
            // metadata resolution must receive each identity exactly once, in first-seen order.
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/trash",
                responses: [
                    (status: 200, json: #"{"Code":1000,"Trash":[{"ShareID":"s1","LinkIDs":["a","b"]}]}"#),
                    (status: 200, json: #"{"Code":1000,"Trash":[{"ShareID":"s1","LinkIDs":["b","c"]}]}"#),
                    (status: 200, json: #"{"Code":1000,"Trash":[]}"#),
                ]
            )
            StubURLProtocol.route(
                "POST /drive/shares/s1/links/fetch_metadata",
                json: #"""
                    {"Code":1000,"Links":[
                        {"LinkID":"a","Type":2,"CreateTime":1700000000},
                        {"LinkID":"b","Type":2,"CreateTime":1700000001},
                        {"LinkID":"c","Type":2,"CreateTime":1700000002}
                    ]}
                    """#)

            let links = try await makeSession().listTrash(volumeID: "vol1", pageSize: 2)

            #expect(links.count == 3)
            #expect(links.map(\.linkID) == ["a", "b", "c"])

            let metadataRequest = try #require(
                StubURLProtocol.requests().first { $0.path == "/drive/shares/s1/links/fetch_metadata" })
            #expect(try linkIDs(inBodyOf: metadataRequest) == ["a", "b", "c"], "deduped, first-seen order")
        }

        @Test func trashLinkDecodeToleratesSparseEntries() throws {
            // Per-item sparseness must not fail the whole listing.
            let json = #"{"Links":[{"LinkID":"only-id"},{"Type":2},{}]}"#
            struct Wrapper: Decodable {
                let links: [TrashLink]
                enum CodingKeys: String, CodingKey { case links = "Links" }
            }
            let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
            #expect(decoded.links.count == 3)
            #expect(decoded.links[0].linkID == "only-id")
            #expect(decoded.links[1].type == 2)
            #expect(decoded.links[2].captureTime == 0)
        }
    }
}

extension DriveSessionStubSuite {
    @Suite struct DriveSessionVolumeEventTests {
        @Test func latestEventUsesTheVolumeScopedEndpoint() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/latest",
                json: #"{"Code":1000,"EventID":"event-100"}"#
            )

            let eventID = try await makeSession().latestVolumeEventID(volumeID: "vol1")

            #expect(eventID == "event-100")
            let request = try #require(StubURLProtocol.requests().first)
            #expect(request.method == "GET")
            #expect(request.path == "/drive/volumes/vol1/events/latest")
        }

        @Test func eventPageDecodesDeleteAndActivePhotoChanges() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/event-100",
                json: #"""
                    {
                      "Code": 1000,
                      "EventID": "event-101",
                      "More": 1,
                      "Refresh": 0,
                      "Events": [
                        {
                          "EventType": 0,
                          "Link": {"LinkID": "deleted-link"}
                        },
                        {
                          "EventType": 2,
                          "ContextShareID": "photos-share",
                          "Link": {"LinkID": "updated-link", "Type": 2, "State": 1}
                        }
                      ]
                    }
                    """#)

            let page = try await makeSession().fetchVolumeEvents(volumeID: "vol1", since: "event-100")

            #expect(page.eventID == "event-101")
            #expect(page.hasMore)
            #expect(!page.requiresRefresh)
            #expect(page.events.count == 2)
            #expect(page.events[0].eventType == 0)
            #expect(page.events[0].linkID == "deleted-link")
            #expect(page.events[0].contextShareID == nil)
            #expect(page.events[1].eventType == 2)
            #expect(page.events[1].contextShareID == "photos-share")
            #expect(page.events[1].linkType == 2)
            #expect(page.events[1].linkState == 1)
            #expect(StubURLProtocol.requests().first?.path == "/drive/volumes/vol1/events/event-100")
        }

        @Test func refreshFlagIsNotMistakenForAnEmptyDelta() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/stale",
                json: #"""
                    {"Code":1000,"EventID":"event-200","More":0,"Refresh":1,"Events":[]}
                    """#)

            let page = try await makeSession().fetchVolumeEvents(volumeID: "vol1", since: "stale")

            #expect(page.requiresRefresh)
            #expect(!page.hasMore)
            #expect(page.events.isEmpty)
        }
    }
}
