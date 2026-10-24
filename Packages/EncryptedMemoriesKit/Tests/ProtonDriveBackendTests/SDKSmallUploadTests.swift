import AppleSecurityCore
import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// SDK 0.31.1 sends small files as one buffered multipart request through `requestSmallUpload`.
/// The transport must keep the opaque body byte-identical, authenticate with the session, never
/// resend after an ambiguous failure, and keep the existing one-shot refresh after an explicit 401.
@Suite("SDK small upload transport", .serialized)
struct SDKSmallUploadTests {
    private let endpoint = "https://drive-api.proton.me/drive/photos/volumes/fixture/files"
    private let endpointPath = "/drive/photos/volumes/fixture/files"
    private let multipartBody =
        Data([0, 255, 13, 10]) + Data("--boundary\r\nopaque multipart\r\n--boundary--".utf8)
    private let multipartContentType = "multipart/form-data; boundary=boundary"
    private let metadata = Data(#"{"Name":"metadata must not replace the multipart body"}"#.utf8)

    @Test func sendsOpaqueMultipartBodyOnceWithSessionAuthentication() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])

        let response = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata,
            headers: [("Content-Type", [multipartContentType])]
        ).get()

        #expect(response.statusCode == 200)
        #expect(response.data == Data("response".utf8))
        let request = try #require(SmallUploadURLProtocol.uploads.only)
        #expect(request.path == endpointPath)
        #expect(request.body == multipartBody, "the multipart body must reach the wire unchanged")
        #expect(request.headers["content-type"] == multipartContentType)
        #expect(request.headers["accept"] == "application/vnd.protonmail.v1+json")
        #expect(request.headers["authorization"] == "Bearer test-access")
        #expect(request.headers["x-pm-uid"] == "test-uid")
        #expect(
            request.headers.values.allSatisfy { !$0.contains("metadata must not") },
            "the plaintext metadata side channel must never become a header")
        #expect(SmallUploadURLProtocol.refreshes.isEmpty)
    }

    @Test func keepsTheSDKContentTypeInsteadOfTheDriveJSONDefault() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])

        _ = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata, headers: []
        ).get()

        let request = try #require(SmallUploadURLProtocol.uploads.only)
        #expect(
            request.headers["content-type"] == nil,
            "a multipart body without an SDK Content-Type must not be relabelled as JSON")
    }

    @Test(arguments: [400, 403, 409, 422, 429, 500, 502, 503])
    func returnsHTTPFailuresWithoutResending(status: Int) async throws {
        // A second attempt would succeed. It must never be made.
        SmallUploadURLProtocol.reset(uploadStatuses: [status, 200])

        let response = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata,
            headers: [("Content-Type", [multipartContentType])]
        ).get()

        #expect(response.statusCode == status)
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        #expect(SmallUploadURLProtocol.refreshes.isEmpty)
    }

    @Test func unauthorizedResponseRefreshesOnceAndResendsTheSameBody() async throws {
        SmallUploadURLProtocol.reset(
            uploadStatuses: [401, 200],
            refresh: (200, #"{"AccessToken":"new-access","RefreshToken":"new-refresh"}"#)
        )

        let response = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata,
            headers: [("Content-Type", [multipartContentType])]
        ).get()

        #expect(response.statusCode == 200)
        #expect(
            SmallUploadURLProtocol.requests.map(\.path)
                == [endpointPath, SmallUploadURLProtocol.refreshPath, endpointPath],
            "exactly one refresh may sit between the rejected and the resent upload")
        let uploads = SmallUploadURLProtocol.uploads
        #expect(uploads.map { $0.headers["authorization"] } == ["Bearer test-access", "Bearer new-access"])
        #expect(uploads.allSatisfy { $0.body == multipartBody })
        #expect(uploads.allSatisfy { $0.headers["content-type"] == multipartContentType })
    }

    @Test func secondUnauthorizedResponseAfterRefreshIsReturnedWithoutAnotherAttempt() async throws {
        SmallUploadURLProtocol.reset(
            uploadStatuses: [401, 401, 200],
            refresh: (200, #"{"AccessToken":"new-access","RefreshToken":"new-refresh"}"#)
        )

        let response = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata,
            headers: [("Content-Type", [multipartContentType])]
        ).get()

        #expect(response.statusCode == 401)
        #expect(SmallUploadURLProtocol.uploads.count == 2, "the refreshed resend is the last attempt")
        #expect(SmallUploadURLProtocol.refreshes.count == 1)
    }

    @Test(arguments: [307, 308, 302])
    func redirectsAreNotFollowed(status: Int) async throws {
        SmallUploadURLProtocol.reset(
            uploadStatuses: [status],
            redirectLocation: "https://untrusted.invalid/drive/photos/volumes/fixture/files"
        )

        let response = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata,
            headers: [("Content-Type", [multipartContentType])]
        ).get()

        #expect(response.statusCode == status, "the redirect status must reach the SDK unchanged")
        #expect(
            SmallUploadURLProtocol.requests.map(\.path) == [endpointPath],
            "the authenticated body must never be replayed to the redirect target")
    }

    @Test func failedRefreshReturnsUnauthorizedWithoutResendingUpload() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [401, 200], refresh: (401, "{}"))

        let response = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata,
            headers: [("Content-Type", [multipartContentType])]
        ).get()

        #expect(response.statusCode == 401)
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        #expect(SmallUploadURLProtocol.refreshes.count == 1)
    }

    @Test(arguments: [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost])
    func ambiguousTransportFailuresNeverResend(code: URLError.Code) async {
        SmallUploadURLProtocol.reset(uploadStatuses: [200], uploadFailure: code)

        let result = await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata,
            headers: [("Content-Type", [multipartContentType])]
        )

        guard case .failure(let error) = result else {
            Issue.record("Expected the original transport failure")
            return
        }
        #expect(error.domain == NSURLErrorDomain)
        #expect(error.code == code.rawValue)
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        #expect(SmallUploadURLProtocol.refreshes.isEmpty)
    }

    @Test(arguments: [
        "http://drive-api.proton.me/drive/photos/volumes/fixture/files",
        "https://untrusted.invalid/drive/photos/volumes/fixture/files",
        "https://drive-api.proton.me.untrusted.invalid/drive/photos/volumes/fixture/files",
    ])
    func refusesUntrustedUploadDestinations(url: String) async {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])

        let result = await makeClient().requestSmallUpload(
            method: "POST", url: url, content: multipartBody, metadata: metadata, headers: []
        )

        guard case .failure = result else {
            Issue.record("Expected destination rejection before authentication or transport")
            return
        }
        #expect(SmallUploadURLProtocol.requests.isEmpty)
    }

    @Test func backupUploadLetsTheSystemRefuseCellularDataWhileMobileDataIsOff() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])
        let access = ExpensiveUploadAccess()
        access.begin(allowsExpensiveNetwork: false)

        _ = try await makeClient(expensiveUploadAccess: access).requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata, headers: []
        ).get()

        #expect(SmallUploadURLProtocol.uploads.only?.allowsExpensiveNetworkAccess == false)
        let storage = makeClient(expensiveUploadAccess: access).storageUploadRequest(
            method: "POST", url: URL(string: "https://storage.invalid/block")!, headers: [],
            body: InputStream(data: Data([1])))
        #expect(!storage.allowsExpensiveNetworkAccess, "encrypted blocks are upload bytes, too")
    }

    @Test func apiRequestsKeepEveryNetworkDuringABackupUpload() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])
        let access = ExpensiveUploadAccess()
        access.begin(allowsExpensiveNetwork: false)

        _ = try await makeClient(expensiveUploadAccess: access).requestDriveApi(
            method: "GET", relativePath: "drive/https://drive-api.proton.me/v2/shares/photos", content: Data(),
            headers: []
        ).get()

        #expect(SmallUploadURLProtocol.requests.only?.allowsExpensiveNetworkAccess == true)
    }

    @Test func uploadsUseEveryNetworkWithoutARestrictedUpload() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])

        _ = try await makeClient().requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata, headers: []
        ).get()

        #expect(SmallUploadURLProtocol.uploads.only?.allowsExpensiveNetworkAccess == true)
    }

    private func makeClient(expensiveUploadAccess: ExpensiveUploadAccess? = nil) -> SDKHttpClient {
        let governor = ProtonRequestGovernor()
        let session = DriveSession(
            session: ProtonSession(
                uid: "test-uid", accessToken: "test-access", refreshToken: "test-refresh", keyPassword: "test-key"),
            store: SessionKeychainStore(
                service: "at.oncloud.encryptedmemories.tests.small-upload-\(UUID().uuidString)",
                account: "default",
                keychain: MemoryKeychainStore()
            ),
            accountCacheDirectory: FileManager.default.temporaryDirectory,
            requestGovernor: governor,
            urlProtocolClasses: [SmallUploadURLProtocol.self]
        )
        return SDKHttpClient(
            driveSession: session, requestGovernor: governor, expensiveUploadAccess: expensiveUploadAccess,
            urlProtocolClasses: [SmallUploadURLProtocol.self]
        )
    }
}

/// Records every request and answers uploads from a status sequence and the token refresh from a
/// fixed response. State is static because URLSession instantiates the protocol itself.
private final class SmallUploadURLProtocol: URLProtocol {
    struct Recorded: Sendable {
        let path: String
        let body: Data
        let headers: [String: String]
        let allowsExpensiveNetworkAccess: Bool
    }

    static let refreshPath = "/auth/v4/refresh"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var uploadStatuses: [Int] = [200]
    nonisolated(unsafe) private static var uploadFailure: URLError.Code?
    nonisolated(unsafe) private static var refresh: (status: Int, json: String) = (401, "{}")
    nonisolated(unsafe) private static var redirectLocation: String?
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static var requests: [Recorded] { lock.withLock { recorded } }
    static var uploads: [Recorded] { requests.filter { $0.path != refreshPath } }
    static var refreshes: [Recorded] { requests.filter { $0.path == refreshPath } }

    static func reset(
        uploadStatuses: [Int],
        uploadFailure: URLError.Code? = nil,
        refresh: (status: Int, json: String) = (401, "{}"),
        redirectLocation: String? = nil
    ) {
        lock.withLock {
            self.uploadStatuses = uploadStatuses
            self.uploadFailure = uploadFailure
            self.refresh = refresh
            self.redirectLocation = redirectLocation
            recorded = []
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = Self.body(request)
        let headers = Dictionary(
            (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        let outcome: (status: Int, body: Data, failure: URLError.Code?, location: String?) = Self.lock.withLock {
            Self.recorded.append(
                Recorded(
                    path: url.path, body: body, headers: headers,
                    allowsExpensiveNetworkAccess: request.allowsExpensiveNetworkAccess))
            if url.path == Self.refreshPath {
                return (Self.refresh.status, Data(Self.refresh.json.utf8), nil, nil)
            }
            let status =
                Self.uploadStatuses.count > 1 ? Self.uploadStatuses.removeFirst() : Self.uploadStatuses.first ?? 200
            return (status, Data("response".utf8), Self.uploadFailure, Self.redirectLocation)
        }
        if let failure = outcome.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var headerFields = ["Content-Type": "application/json"]
        if let location = outcome.location { headerFields["Location"] = location }
        let response = HTTPURLResponse(
            url: url, statusCode: outcome.status, httpVersion: "HTTP/1.1", headerFields: headerFields)!
        if let location = outcome.location, (300...399).contains(outcome.status) {
            // Mirror URLSession's redirect handling: the client decides whether the new request is sent.
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: outcome.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class MemoryKeychainStore: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppleKeychainItem: Data] = [:]

    func data(for item: AppleKeychainItem) throws -> Data? {
        lock.withLock { storage[item] }
    }

    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        lock.withLock { storage[item] = data }
    }

    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        lock.withLock {
            if let existing = storage[item] { return existing }
            storage[item] = data
            return data
        }
    }

    func removeData(for item: AppleKeychainItem) throws {
        lock.withLock { _ = storage.removeValue(forKey: item) }
    }

    func removeAllData(service: String) throws {
        lock.withLock { storage = storage.filter { $0.key.service != service } }
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
