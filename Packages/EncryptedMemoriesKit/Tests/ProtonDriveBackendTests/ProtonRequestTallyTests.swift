import AlbumCore
import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend

@Suite("Proton request counts")
struct ProtonRequestTallyTests {
    private static let volumeID =
        "Xk3vR9aQ2mZ0pL7wB4nT8yHc6uJ1eFgS5dKqV0oWbN2iM9rA7tY3xC8zE4hU6jG1fP5lD0sQ9vB2nK7wR3mT8yX4c=="
    private static let linkID =
        "aB9cD8eF7gH6iJ5kL4mN3oP2qR1sT0uV9wX8yZ7AbC6dE5fG4hI3jK2lM1nO0pQ9rS8tU7vW6xY5zA4bC3dE2fG1hI=="

    @Test func endpointTemplatesKeepOnlyFixedPathWords() {
        let label = ProtonRequestLabel.api(
            method: "get",
            path: "/drive/v2/volumes/\(Self.volumeID)/links/\(Self.linkID)/trash_multiple?Page=2&PageSize=150"
        )
        #expect(
            label == ProtonRequestLabel(method: "GET", endpoint: "/drive/v2/volumes/{id}/links/{id}/trash_multiple"))
        #expect(
            ProtonRequestLabel.api(method: "POST", path: "/drive/photos/volumes/abc123/albums/x/add-multiple").endpoint
                == "/drive/photos/volumes/{id}/albums/{id}/add-multiple")
        #expect(ProtonRequestLabel.api(method: "PROPFIND", path: "/core/v4/users").method == "OTHER")
        #expect(ProtonRequestLabel.storage(method: "put") == ProtonRequestLabel(method: "PUT", endpoint: "<storage>"))
        // Mixed case, digits, padding and long words are identifiers; only short lowercase words and versions stay.
        for segment in ["AbCd", "a1", "abc=", "v", "x", "ab", "v4x", "v12345", String(repeating: "a", count: 33)] {
            #expect(!ProtonRequestLabel.isFixedWord(Substring(segment)), "\(segment)")
        }
        for segment in ["v4", "fetch_metadata", "add-multiple", "latest"] {
            #expect(ProtonRequestLabel.isFixedWord(Substring(segment)), "\(segment)")
        }
    }

    @Test(arguments: [
        // (path, expected endpoint)
        ("/drive/volumes/550e8400-e29b-41d4-a716-446655440000/photos", "/drive/volumes/{id}/photos"),
        ("/drive/shares/1234567/links", "/drive/shares/{id}/links"),
        ("/drive/links/0123456789abcdef0123456789abcdef", "/drive/links/{id}"),
        (
            "/drive/links/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/revisions",
            "/drive/links/{id}/revisions"
        ),
        ("/drive/files/Holiday photo.jpg", "/drive/files/{id}"),
        ("/drive/files/café", "/drive/files/{id}"),
        ("/drive/files/my%20photo", "/drive/files/{id}"),
        // The fragment is dropped like the query, whatever it contains.
        ("/drive/events/latest#fragment", "/drive/events/latest"),
        ("/drive/events/latest#note/alice", "/drive/events/latest"),
        ("/drive/shares?next=/alice/x", "/drive/shares"),
        // An input with a scheme is a full URL: only its path is segmented, never its host.
        ("https://drive-api.proton.me/drive/shares", "/drive/shares"),
        ("https://alice/drive/shares", "/drive/shares"),
        ("https://alice", "/"),
        ("https://alice?x/drive", "/"),
        ("ftp://alice#frag/drive/shares", "/"),
        // "://" inside the query or the fragment is no scheme.
        ("/drive/shares?next=https://alice/x", "/drive/shares"),
        ("/drive/shares#http://alice/y", "/drive/shares"),
        ("", "/"),
        ("//drive//shares//", "/drive/shares"),
        ("/drive/shares/", "/drive/shares"),
    ])
    func endpointTemplatesHideEveryIdentifierShape(path: String, expected: String) {
        #expect(ProtonRequestLabel.api(method: "GET", path: path).endpoint == expected)
    }

    @Test func aLowercaseOnlyIdentifierOfRouteWordLengthIsKeptByTheShapeRule() {
        // The rule keeps the shape of a route word; it does not know the route words. Proton identifiers carry
        // digits or capitals, so they never take this shape. This test records the limit instead of hiding it.
        let word = "abcdefghijklmnopqrstuv"
        #expect(word.count == 22)
        let endpoint = ProtonRequestLabel.api(method: "GET", path: "/drive/shares/\(word)").endpoint
        #expect(endpoint == "/drive/shares/\(word)")
    }

    @Test func onlyASCIILettersCountAsRouteWordLetters() {
        // "b" followed by a combining long solidus overlay compares as a Character between "a" and "z".
        let combined = "ab\u{0338}cdef"
        #expect(!ProtonRequestLabel.isFixedWord(Substring(combined)))
        #expect(ProtonRequestLabel.api(method: "GET", path: "/drive/\(combined)").endpoint == "/drive/{id}")
        #expect(!ProtonRequestLabel.isFixedWord(Substring("v\u{0664}")))
    }

    @Test func requestLabelsComeFromThePathOrNothingForStorage() throws {
        func request(_ url: String, method: String = "GET") throws -> URLRequest {
            var request = URLRequest(url: try #require(URL(string: url)))
            request.httpMethod = method
            return request
        }
        let api = try request(
            "https://drive-api.proton.me/drive/v2/volumes/AbC123==/trash_multiple?Page=1#top", method: "POST")
        #expect(
            SDKHttpClient.label(for: api, scope: .api)
                == ProtonRequestLabel(method: "POST", endpoint: "/drive/v2/volumes/{id}/trash_multiple"))
        let encoded = try request("https://drive-api.proton.me/drive/files/my%20photo.jpg")
        #expect(SDKHttpClient.label(for: encoded, scope: .api).endpoint == "/drive/files/{id}")
        // An encoded segment that decodes to a route-word shape is still an identifier.
        let encodedWord = try request("https://drive-api.proton.me/drive/shares/%61%62%63%64/links")
        #expect(SDKHttpClient.label(for: encodedWord, scope: .api).endpoint == "/drive/shares/{id}/links")
        let storage = try request("https://storage.proton.me/blocks/AbC123?token=secret", method: "PUT")
        #expect(
            SDKHttpClient.label(for: storage, scope: .storageUpload)
                == ProtonRequestLabel(method: "PUT", endpoint: "<storage>"))
        #expect(SDKHttpClient.label(for: storage, scope: .storageDownload).endpoint == "<storage>")
    }

    @Test func statusCodesFallIntoTheReportedClasses() {
        let cases: [(Int?, ProtonRequestStatusClass)] = [
            (nil, .transport), (200, .success), (204, .success), (302, .redirect), (401, .unauthorized),
            (404, .notFound), (408, .timeout), (429, .rateLimited), (422, .clientError), (503, .serverError),
            (99, .transport),
        ]
        for (code, expected) in cases {
            #expect(ProtonRequestStatusClass(statusCode: code) == expected, "\(String(describing: code))")
        }
        // A cancelled request is no network failure; a response that arrived keeps its own class.
        #expect(ProtonRequestStatusClass(statusCode: nil, cancelled: true) == .cancelled)
        #expect(ProtonRequestStatusClass(statusCode: 200, cancelled: true) == .success)
        #expect(ProtonRequestStatusClass.isCancellation(CancellationError()))
        #expect(ProtonRequestStatusClass.isCancellation(URLError(.cancelled)))
        #expect(!ProtonRequestStatusClass.isCancellation(URLError(.timedOut)))
        #expect(!ProtonRequestStatusClass.isCancellation(URLError(.notConnectedToInternet)))
    }

    @Test func aCancelledDriveSessionRequestCountsAsCancelledNotAsTransport() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let session = DriveSession(
            session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
            store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
            accountCacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("request-tally-tests-\(UUID().uuidString)"),
            requestGovernor: governor,
            urlProtocolClasses: [NeverAnsweringURLProtocol.self]
        )
        let request = Task {
            let _: EmptyResponse = try await session.getJSON("/core/v4/users", as: EmptyResponse.self)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await governor.snapshot().api.inFlight == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()
        _ = await request.result
        let statuses = await governor.requestSupportSnapshot().counts.map(\.status)
        #expect(statuses == ["cancelled"])
    }

    @Test func governorCountsEachFinishedRequestByEndpointCauseAndStatus() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let label = ProtonRequestLabel.api(method: "GET", path: "/drive/volumes/\(Self.volumeID)/events/latest")
        try await governor.causes.run(.timelineProbe) {
            let ok = try await governor.acquire(scope: .api, label: label)
            await governor.finish(ok, statusCode: 200)
            let failed = try await governor.acquire(scope: .api, label: label)
            await governor.finish(failed, statusCode: nil)
            let again = try await governor.acquire(scope: .api, label: label)
            await governor.finish(again, statusCode: 200)
            // A permit finishes once; a second finish is not a second request.
            await governor.finish(again, statusCode: 200)
        }
        let download = try await governor.acquire(scope: .storageDownload, label: .storage(method: "GET"))
        await governor.finish(download, statusCode: 503)

        let snapshot = await governor.requestSupportSnapshot()
        #expect(
            snapshot.counts == [
                .init(
                    scope: "api", method: "GET", endpoint: "/drive/volumes/{id}/events/latest",
                    cause: "timeline.probe", status: "2xx", count: 2),
                .init(
                    scope: "api", method: "GET", endpoint: "/drive/volumes/{id}/events/latest",
                    cause: "timeline.probe", status: "transport", count: 1),
                .init(
                    scope: "storageDownload", method: "GET", endpoint: "<storage>",
                    cause: "unattributed", status: "5xx", count: 1),
            ])
        #expect(snapshot.overflowRequests == 0)
        #expect(snapshot.scopes.map(\.scope) == ["api", "storageDownload", "storageUpload"])
    }

    @Test func callbackRequestsWithoutATaskCauseAreMarkedAsInferred() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let scopes = governor.causes
        let label = ProtonRequestLabel.api(method: "POST", path: "/drive/shares/x/links/fetch_metadata")
        // A native SDK callback starts a new task, so it carries no task-local cause.
        func callback() async throws {
            let permit = try await Task.detached { try await governor.acquire(scope: .api, label: label) }.value
            await governor.finish(permit, statusCode: 200)
        }
        try await callback()
        try await scopes.run(.thumbnails) { try await callback() }
        // Local work sends no request, so it never appears in an inferred cause.
        try await scopes.run(.local) { try await callback() }
        try await scopes.run(.thumbnails) {
            try await Task.detached {
                try await scopes.run(.timelineFull) { try await callback() }
            }.value
        }
        let causes = await governor.requestSupportSnapshot().counts.map(\.cause)
        #expect(causes == ["unattributed", "~thumbnails", "~thumbnails+timeline.full"])
        let unattributed = await governor.requestSupportSnapshot().counts.first { $0.cause == "unattributed" }
        #expect(unattributed?.count == 2)
    }

    /// The viewer's lookup of an edited photo's original counts under its own code-owned name.
    @Test func theOriginalLookupOfTheViewerCountsUnderItsOwnCause() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let label = ProtonRequestLabel.api(method: "POST", path: "/drive/photos/volumes/\(Self.volumeID)/links")
        try await governor.causes.run(.viewerOriginal) {
            let permit = try await governor.acquire(scope: .api, label: label)
            await governor.finish(permit, statusCode: 200)
        }
        let counts = await governor.requestSupportSnapshot().counts
        #expect(
            counts == [
                .init(
                    scope: "api", method: "POST", endpoint: "/drive/photos/volumes/{id}/links",
                    cause: "viewer.original", status: "2xx", count: 1)
            ])
    }

    @Test func anEnclosingCauseWinsUnlessTheWorkReplacesIt() async throws {
        let scopes = ProtonRequestCauseScopes()
        let nested = await scopes.run(.duplicatesMerge) {
            await scopes.run(.trashWrite) { ProtonRequestContext.cause }
        }
        #expect(nested == .duplicatesMerge)
        let replaced = await scopes.run(.timelineFull) {
            await scopes.run(.trashList, replacing: true) { ProtonRequestContext.cause }
        }
        #expect(replaced == .trashList)
        #expect(scopes.resolve(taskCause: nil) == "unattributed")
    }

    @Test func rateLimitsRecordTheLargestRetryAfterAndCooldownWithoutOverlap() async throws {
        let clock = TallyTestClock()
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(initial: 4), now: { clock.now }, summaryLog: { _ in })
        let first = try await governor.acquire(scope: .api)
        let second = try await governor.acquire(scope: .api)
        let third = try await governor.acquire(scope: .api)
        await governor.finish(first, statusCode: 429, retryAfter: 10)
        // A second 429 whose cooldown ends inside the first adds no cooldown time.
        await governor.finish(second, statusCode: 429, retryAfter: 4)
        // A third 429 extends the cooldown by 5 s beyond the first one.
        clock.now = clock.now.addingTimeInterval(5)
        await governor.finish(third, statusCode: 429, retryAfter: 10)

        let api = try #require(await governor.requestSupportSnapshot().scopes.first { $0.scope == "api" })
        #expect(api.maximumRetryAfterSeconds == 10)
        #expect(api.totalCooldownSeconds == 15)
        #expect(api.peakInFlight == 3)
        #expect(api.rateLimitedLastMinute == 3)
        let download = try #require(
            await governor.requestSupportSnapshot().scopes.first { $0.scope == "storageDownload" })
        #expect(download.maximumRetryAfterSeconds == nil)
        #expect(download.totalCooldownSeconds == 0)
    }

    @Test func aNonFiniteRetryAfterNeverReachesTheReport() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        // Both permits first: after a 429 the governor holds the scope for the cooldown.
        let permit = try await governor.acquire(scope: .api)
        let negative = try await governor.acquire(scope: .api)
        await governor.finish(permit, statusCode: 429, retryAfter: .infinity)
        // A negative value that reaches the tally directly is not a maximum either. A negative header never does:
        // the parser reads it as 0 seconds (see the next test).
        await governor.finish(negative, statusCode: 429, retryAfter: -5)
        let snapshot = await governor.requestSupportSnapshot()
        let api = try #require(snapshot.scopes.first { $0.scope == "api" })
        #expect(api.maximumRetryAfterSeconds == nil)
        #expect(api.totalCooldownSeconds.isFinite)
        // The support report encodes with the default strategy, which throws on a non-finite number.
        _ = try JSONEncoder().encode(snapshot)
    }

    @Test func aNegativeRetryAfterHeaderCountsAsZeroSeconds() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let url = try #require(URL(string: "https://drive-api.invalid/drive/shares"))
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "-5"]))
        // The production parser clamps the header before the tally sees it.
        let seconds = try #require(ProtonRetryAfter.seconds(from: response))
        #expect(seconds == 0)
        let permit = try await governor.acquire(scope: .api)
        await governor.finish(permit, statusCode: 429, retryAfter: seconds)
        let api = try #require(await governor.requestSupportSnapshot().scopes.first { $0.scope == "api" })
        #expect(api.maximumRetryAfterSeconds == 0)
    }

    @Test func servicesOutsideTheBridgeNameTheirCauseThroughTheirShutdownGate() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let resolver = ShutdownGatedUploadIdentityResolver(
            base: RequestingResolver(governor: governor),
            admission: JoinedShutdownGate(),
            requestCause: ProtonRequestCauseBinding(scopes: governor.causes, cause: .backup)
        )
        await resolver.prime([])
        // An enclosing cause still wins, so a duplicate merge that checks uploads stays a merge.
        await governor.causes.run(.duplicatesMerge) { await resolver.prime([]) }
        let causes = await governor.requestSupportSnapshot().counts.map(\.cause)
        #expect(causes == ["backup", "duplicates.merge"])
    }

    @Test func theDuplicatesScreenNamesItsOwnIndexBuild() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let backup = ShutdownGatedUploadIdentityResolver(
            base: RequestingResolver(governor: governor),
            admission: JoinedShutdownGate(),
            requestCause: ProtonRequestCauseBinding(scopes: governor.causes, cause: .backup)
        )
        let duplicates = backup.naming(ProtonRequestCauseBinding(scopes: governor.causes, cause: .duplicatesRead))
        await duplicates.prime([])
        await backup.prime([])
        let causes = await governor.requestSupportSnapshot().counts.map(\.cause)
        #expect(causes == ["backup", "duplicates.read"])
    }

    @Test func theAlbumCarryOverOfAMergeIsNotCountedAsAlbumWork() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let albumCause = ProtonRequestCauseBinding(scopes: governor.causes, cause: .albums)
        let backend = RequestingAlbumBackend(governor: governor, cause: albumCause)
        let carryOver = AlbumRepositorySeriesCarryOver(
            repository: AlbumsRepository(catalogBackend: backend, writeBackend: backend),
            requestCause: ProtonRequestCauseBinding(scopes: governor.causes, cause: .carryOver)
        )
        _ = try await carryOver.currentAlbums(containing: [PhotoUID(volumeID: "v", nodeID: "n")])
        try await carryOver.addPhotos([PhotoUID(volumeID: "v", nodeID: "n")], toOwnAlbum: "album")
        // The person's own album work keeps its cause.
        _ = try await backend.listAlbums()
        let counts = await governor.requestSupportSnapshot().counts
        #expect(counts.map(\.cause) == ["albums", "carryover"])
        #expect(counts.map(\.count) == [1, 2])
    }

    @Test func oneSummaryLinePerMinuteCoversThePreviousMinute() async throws {
        let clock = TallyTestClock()
        let lines = SummaryRecorder()
        let governor = ProtonRequestGovernor(now: { clock.now }, summaryLog: { lines.append($0) })
        func request(_ cause: ProtonRequestCause, status: Int?) async throws {
            try await governor.causes.run(cause) {
                let permit = try await governor.acquire(scope: .api)
                await governor.finish(permit, statusCode: status)
            }
        }
        try await request(.thumbnails, status: 200)
        clock.now = clock.now.addingTimeInterval(30)
        try await request(.timelineFull, status: 503)
        try await request(.thumbnails, status: 200)
        #expect(lines.values.isEmpty)

        clock.now = clock.now.addingTimeInterval(31)
        try await request(.viewer, status: 200)
        #expect(
            lines.values == [
                [
                    "requests": "3", "windowSeconds": "61", "causes": "thumbnails:2,timeline.full:1",
                    "statuses": "2xx:2,5xx:1",
                ]
            ])

        clock.now = clock.now.addingTimeInterval(120)
        try await request(.viewer, status: nil)
        #expect(lines.values.count == 2)
        // The window after an idle period is longer than a minute and says so.
        #expect(
            lines.values.last == ["requests": "1", "windowSeconds": "120", "causes": "viewer:1", "statuses": "2xx:1"])
    }

    @Test func theKeyTableStaysBoundedAndCountsTheRestAsOverflow() {
        var tally = ProtonRequestTally()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<(ProtonRequestTally.maximumKeys + 3) {
            _ = tally.record(
                .init(scope: .api, method: "GET", endpoint: "/e\(index)", cause: "c", status: .success), at: start)
        }
        // A known key still counts after the table is full.
        _ = tally.record(.init(scope: .api, method: "GET", endpoint: "/e0", cause: "c", status: .success), at: start)
        #expect(tally.counts.count == ProtonRequestTally.maximumKeys)
        #expect(tally.overflowRequests == 3)
        #expect(tally.counts[.init(scope: .api, method: "GET", endpoint: "/e0", cause: "c", status: .success)] == 2)
    }

    @Test func driveSessionRequestsAreCountedWithoutIdentifiersOrQuery() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let session = DriveSession(
            session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
            store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
            accountCacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("request-tally-tests-\(UUID().uuidString)"),
            requestGovernor: governor,
            urlProtocolClasses: [AlwaysOKURLProtocol.self]
        )
        let path = "/drive/shares/\(Self.volumeID)/links/\(Self.linkID)?Thumbnails=1"
        let _: EmptyResponse = try await governor.causes.run(.viewerMetadata) {
            try await session.getJSON(path, as: EmptyResponse.self)
        }
        let snapshot = await governor.requestSupportSnapshot()
        #expect(
            snapshot.counts == [
                .init(
                    scope: "api", method: "GET", endpoint: "/drive/shares/{id}/links/{id}",
                    cause: "viewer.metadata", status: "2xx", count: 1)
            ])
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains(String(Self.volumeID.prefix(12))))
        #expect(!encoded.contains(String(Self.linkID.prefix(12))))
        #expect(!encoded.contains("Thumbnails"))
    }

    @Test func supportSourceRegistrationBelongsToOneSession() async throws {
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let old = ProtonRequestGovernor(summaryLog: { _ in })
        let current = ProtonRequestGovernor(summaryLog: { _ in })
        let permit = try await current.acquire(scope: .api, label: .api(method: "GET", path: "/core/v4/users"))
        await current.finish(permit, statusCode: 200)

        sources.registerRequests(old)
        sources.registerRequests(current)
        sources.unregisterRequests(old)
        #expect(await sources.requestSnapshot()?.counts.map(\.endpoint) == ["/core/v4/users"])
        sources.unregisterRequests(current)
        #expect(await sources.requestSnapshot() == nil)
    }

    private static func configuration(initial: Int) -> ProtonRequestGovernor.Configuration {
        let scope = ProtonRequestGovernor.Configuration.Scope(initialConcurrency: initial, maximumConcurrency: initial)
        return .init(
            api: scope, storageDownload: scope, storageUpload: scope, successWindowForIncrease: 32,
            starvationPromotionInterval: 10, priorityScopeLifetime: 60)
    }
}

private struct EmptyResponse: Decodable {}

/// Sends one counted request from `prime`, the way the real pipeline reaches the network.
private struct RequestingResolver: UploadIdentityResolving {
    let governor: ProtonRequestGovernor

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        throw CancellationError()
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String
    ) async throws {}

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        guard
            let permit = try? await governor.acquire(
                scope: .api, label: .api(method: "POST", path: "/drive/volumes/x/photos/duplicates"))
        else { return }
        await governor.finish(permit, statusCode: 200)
    }
}

private final class AlwaysOKURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Counts one request per call under the album services' own cause, like the real album backends.
private struct RequestingAlbumBackend: AlbumCatalogBackend, AlbumWriteBackend {
    let governor: ProtonRequestGovernor
    let cause: ProtonRequestCauseBinding

    private func request() async throws {
        try await cause.run {
            let permit = try await governor.acquire(scope: .api)
            await governor.finish(permit, statusCode: 200)
        }
    }

    func listAlbums() async throws -> [AlbumSummary] {
        try await request()
        return []
    }
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {}
    func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        try await request()
        return [:]
    }
    func createAlbum(name: String) async throws -> AlbumID { AlbumID(name) }
    func deleteAlbum(albumID: AlbumID) async throws {}
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws { try await request() }
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {}
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {}
}

/// Holds every request until its task is cancelled, the way a scrolled-away thumbnail fetch ends.
private final class NeverAnsweringURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class TallyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class SummaryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [[String: String]] = []
    var values: [[String: String]] { lock.withLock { lines } }
    func append(_ line: [String: String]) { lock.withLock { lines.append(line) } }
}
