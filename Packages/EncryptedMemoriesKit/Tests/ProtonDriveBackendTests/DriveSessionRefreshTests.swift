import AppleSecurityCore
import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// A 401 for credentials that another request already replaced retries with the new credentials and
/// sends no refresh of its own; a refresh that runs for newer credentials is awaited first.
/// Only the waiter of the current refresh flight can retire it (#535).
@Suite("Drive session token refresh", .serialized)
struct DriveSessionRefreshTests {
    private struct Answer: Decodable {
        let code: Int
        enum CodingKeys: String, CodingKey { case code = "Code" }
    }

    /// The request with the old token gets its 401 only after another request refreshed the token.
    @Test func aLate401AfterARefreshRetriesWithTheNewTokenWithoutRefreshing() async throws {
        let server = RefreshServer.start(holding: [("/tests/held", 1)])
        defer { server.releaseAll() }
        let session = makeSession()

        let held = Task { try await session.getJSON("/tests/held", as: Answer.self) }
        try #require(await server.waitUntilHeld("/tests/held", 1))
        let other = try await session.getJSON("/tests/other", as: Answer.self)
        #expect(other.code == 1000)
        #expect(server.refreshCount == 1)

        server.release("/tests/held", 1)
        let late = try await held.value

        #expect(late.code == 1000)
        #expect(server.refreshCount == 1, "the late 401 must not send a second refresh")
        #expect(server.authorizations(for: "/tests/held") == ["Bearer test-access", "Bearer access-1"])
    }

    @Test func theSDKClientRetriesALate401WithTheNewTokenWithoutRefreshing() async throws {
        let server = RefreshServer.start(holding: [("/drive/tests/held", 1)])
        defer { server.releaseAll() }
        let client = makeClient(makeSession())

        let held = Task {
            await client.requestDriveApi(method: "GET", relativePath: "/drive/tests/held", content: Data(), headers: [])
        }
        try #require(await server.waitUntilHeld("/drive/tests/held", 1))
        let other = try await client.requestDriveApi(
            method: "GET", relativePath: "/drive/tests/other", content: Data(), headers: []
        ).get()
        #expect(other.statusCode == 200)
        #expect(server.refreshCount == 1)

        server.release("/drive/tests/held", 1)
        let late = try await held.value.get()

        #expect(late.statusCode == 200)
        #expect(server.refreshCount == 1, "the late 401 must not send a second refresh")
        #expect(server.authorizations(for: "/drive/tests/held") == ["Bearer test-access", "Bearer access-1"])
    }

    /// A small upload is resent once, with the new token, after its late 401; its body stays the same.
    @Test func aSmallUploadResendsOnceWithTheNewTokenAfterALate401() async throws {
        let server = RefreshServer.start(holding: [("/drive/tests/upload", 1)])
        defer { server.releaseAll() }
        let client = makeClient(makeSession())
        let body = Data("opaque multipart".utf8)

        let held = Task {
            await client.requestSmallUpload(
                method: "POST", url: "https://drive-api.proton.me/drive/tests/upload", content: body,
                metadata: Data(), headers: [])
        }
        try #require(await server.waitUntilHeld("/drive/tests/upload", 1))
        _ = try await client.requestDriveApi(
            method: "GET", relativePath: "/drive/tests/other", content: Data(), headers: []
        ).get()

        server.release("/drive/tests/upload", 1)
        let late = try await held.value.get()

        #expect(late.statusCode == 200)
        #expect(server.refreshCount == 1)
        #expect(server.authorizations(for: "/drive/tests/upload") == ["Bearer test-access", "Bearer access-1"])
        #expect(server.bodies(for: "/drive/tests/upload") == [body, body])
    }

    /// A 401 for old credentials arrives while a refresh for newer credentials runs. It waits for that
    /// refresh instead of retrying with credentials that the server already rejected.
    @Test func anOld401AwaitsTheNewerRefreshInFlight() async throws {
        try await oldGenerationWaitsForTheNewerRefresh(path: "/tests/old") { session, path in
            _ = try await session.getJSON(path, as: Answer.self)
        }
    }

    @Test func theSDKClientAwaitsTheNewerRefreshForAnOld401() async throws {
        try await oldGenerationWaitsForTheNewerRefresh(path: "/drive/tests/old") { session, path in
            let response = try await makeClient(session).requestDriveApi(
                method: "GET", relativePath: path, content: Data(), headers: []
            ).get()
            #expect(response.statusCode == 200)
        }
    }

    /// Request X sent with generation 0; refresh A gave generation 1; then generation 1 was rejected and refresh B
    /// runs. X's 401 arrives while B runs.
    private func oldGenerationWaitsForTheNewerRefresh(
        path: String, request: @escaping @Sendable (DriveSession, String) async throws -> Void
    ) async throws {
        let server = RefreshServer.start(holding: [(path, 1), (RefreshServer.refreshPath, 2)])
        defer { server.releaseAll() }
        let session = makeSession()

        let x = Task { try await request(session, path) }
        try #require(await server.waitUntilHeld(path, 1))
        _ = try await session.getJSON("/tests/a", as: Answer.self)
        server.expireToken()
        let starter = Task { try await session.getJSON("/tests/b", as: Answer.self) }
        try #require(await server.waitUntilHeld(RefreshServer.refreshPath, 2))

        server.release(path, 1)
        // X handles its 401 now. A retry before refresh B ends would reach the server; give it the chance to.
        try #require(await server.waitUntilAnswered(path, 1))
        _ = await server.eventually(timeout: .seconds(1)) { server.authorizations(for: path).count > 1 }
        server.release(RefreshServer.refreshPath, 2)

        try await x.value
        _ = try await starter.value
        #expect(server.refreshCount == 2, "the old 401 joins refresh B and starts none of its own")
        #expect(server.authorizations(for: path) == ["Bearer test-access", "Bearer access-2"])
    }

    @Test func aFailedRefreshReturnsThe401AndTheNextRequestRefreshesAgain() async throws {
        let server = RefreshServer.start(refreshFails: true)
        defer { server.releaseAll() }
        let session = makeSession()

        await #expect(throws: ProtonAuthError.self) { try await session.getJSON("/tests/first", as: Answer.self) }
        await #expect(throws: ProtonAuthError.self) { try await session.getJSON("/tests/second", as: Answer.self) }

        #expect(server.refreshCount == 2, "a failed refresh changes no credentials")
        #expect(server.authorizations(for: "/tests/first") == ["Bearer test-access"])
    }

    /// The session's credentials authenticate a Drive API request even when the caller supplies its own.
    @Test func suppliedHeadersCannotReplaceTheSessionCredentials() async throws {
        let server = RefreshServer.start(firstTokenValid: true)
        defer { server.releaseAll() }

        let response = try await makeClient(makeSession()).requestDriveApi(
            method: "GET", relativePath: "/drive/tests/headers", content: Data(),
            headers: [("Authorization", ["Bearer supplied"]), ("x-pm-uid", ["supplied-uid"])]
        ).get()

        #expect(response.statusCode == 200)
        #expect(server.authorizations(for: "/drive/tests/headers") == ["Bearer test-access"])
        #expect(server.uids(for: "/drive/tests/headers") == ["test-uid"])
    }

    /// A late waiter of an earlier flight must not retire the flight that runs now.
    @Test func aLateWaiterOfAnEarlierFlightKeepsTheCurrentFlight() {
        var flights = RefreshFlight()
        let first = flights.join { Task { true } }
        flights.retire(first.id)
        let second = flights.join { Task { true } }

        flights.retire(first.id)

        #expect(flights.id == second.id)
        let third = flights.join { Task { false } }
        #expect(third.id == second.id, "a new caller joins the current flight")
    }

    @Test func theWaiterOfTheCurrentFlightRetiresIt() {
        var flights = RefreshFlight()
        let flight = flights.join { Task { true } }

        flights.retire(flight.id)

        #expect(flights.id == nil)
        #expect(flights.join { Task { true } }.id != flight.id)
    }

    private func makeSession() -> DriveSession {
        DriveSession(
            session: ProtonSession(
                uid: "test-uid", accessToken: "test-access", refreshToken: "test-refresh", keyPassword: "test-key"),
            store: SessionKeychainStore(
                service: "at.oncloud.encryptedmemories.tests.refresh-\(UUID().uuidString)",
                account: "default",
                keychain: RefreshTestKeychainStore()
            ),
            accountCacheDirectory: FileManager.default.temporaryDirectory,
            urlProtocolClasses: [RefreshServerProtocol.self]
        )
    }

    private func makeClient(_ session: DriveSession) -> SDKHttpClient {
        SDKHttpClient(
            driveSession: session, requestGovernor: session.requestGovernor,
            urlProtocolClasses: [RefreshServerProtocol.self])
    }
}

/// One request that the test holds. It opens once; every exit path of a test opens it, so nothing waits forever.
private final class RequestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    func open() {
        let first = lock.withLock {
            defer { opened = true }
            return !opened
        }
        if first { semaphore.signal() }
    }

    func wait() { _ = semaphore.wait(timeout: .now() + 10) }
}

/// The server of one test. Its first token has expired unless `firstTokenValid`. Every refresh issues the next
/// token `access-<n>`; an API request succeeds only with the newest valid token. Listed occurrences of a path
/// are held until the test releases them. A new test starts a new server, so an old request never reads its state.
private final class RefreshServer: @unchecked Sendable {
    static let refreshPath = "/auth/v4/refresh"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: RefreshServer?

    private struct Recorded {
        let path: String
        let authorization: String?
        let uid: String?
        let body: Data
    }

    private let lock = NSLock()
    private let refreshFails: Bool
    private let holds: Set<String>
    private var issued = 0
    private var newestValid: Bool
    private var seen: [String: Int] = [:]
    private var gates: [String: RequestGate] = [:]
    private var answered: Set<String> = []
    private var recorded: [Recorded] = []

    private init(holding: [(String, Int)], refreshFails: Bool, firstTokenValid: Bool) {
        holds = Set(holding.map { "\($0.0)#\($0.1)" })
        self.refreshFails = refreshFails
        newestValid = firstTokenValid
    }

    static func start(
        holding: [(String, Int)] = [], refreshFails: Bool = false, firstTokenValid: Bool = false
    ) -> RefreshServer {
        let server = RefreshServer(holding: holding, refreshFails: refreshFails, firstTokenValid: firstTokenValid)
        lock.withLock { active = server }
        return server
    }

    static var current: RefreshServer? { lock.withLock { active } }

    var refreshCount: Int { lock.withLock { recorded.filter { $0.path == Self.refreshPath }.count } }

    func authorizations(for path: String) -> [String?] {
        lock.withLock { recorded.filter { $0.path == path }.map(\.authorization) }
    }

    func uids(for path: String) -> [String?] { lock.withLock { recorded.filter { $0.path == path }.map(\.uid) } }

    func bodies(for path: String) -> [Data] { lock.withLock { recorded.filter { $0.path == path }.map(\.body) } }

    /// The newest token stops working until the next refresh.
    func expireToken() { lock.withLock { newestValid = false } }

    func release(_ path: String, _ occurrence: Int) {
        lock.withLock { gates["\(path)#\(occurrence)"] }?.open()
    }

    func releaseAll() { lock.withLock { Array(gates.values) }.forEach { $0.open() } }

    func waitUntilHeld(_ path: String, _ occurrence: Int) async -> Bool {
        await eventually(timeout: .seconds(5)) { self.lock.withLock { self.gates["\(path)#\(occurrence)"] != nil } }
    }

    func waitUntilAnswered(_ path: String, _ occurrence: Int) async -> Bool {
        let key = "\(path)#\(occurrence)"
        return await eventually(timeout: .seconds(5)) { self.lock.withLock { self.answered.contains(key) } }
    }

    /// Polls a condition up to `timeout`; a false result is for the caller to judge.
    func eventually(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The gate of this request when the test holds it.
    func arrive(_ path: String) -> (key: String, gate: RequestGate?) {
        lock.withLock {
            let occurrence = (seen[path] ?? 0) + 1
            seen[path] = occurrence
            let key = "\(path)#\(occurrence)"
            guard holds.contains(key) else { return (key, nil) }
            let gate = RequestGate()
            gates[key] = gate
            return (key, gate)
        }
    }

    func answer(key: String, path: String, request: URLRequest, body: Data) -> (status: Int, body: String) {
        lock.withLock {
            answered.insert(key)
            recorded.append(
                Recorded(
                    path: path, authorization: request.value(forHTTPHeaderField: "Authorization"),
                    uid: request.value(forHTTPHeaderField: "x-pm-uid"), body: body))
            if path == Self.refreshPath {
                if refreshFails { return (401, "{}") }
                issued += 1
                newestValid = true
                return (200, #"{"AccessToken":"access-\#(issued)","RefreshToken":"refresh-\#(issued)"}"#)
            }
            let newest = issued > 0 ? "Bearer access-\(issued)" : "Bearer test-access"
            let accepted = newestValid && request.value(forHTTPHeaderField: "Authorization") == newest
            return accepted ? (200, #"{"Code":1000}"#) : (401, "{}")
        }
    }
}

private final class RefreshServerProtocol: URLProtocol {
    private var gate: RequestGate?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = RefreshServer.current else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let path = request.url!.path
        let body = Self.body(request)
        let (key, gate) = server.arrive(path)
        self.gate = gate
        guard let gate else { return respond(server.answer(key: key, path: path, request: request, body: body)) }
        // Answer from another queue once the test releases it; the token check runs at answer time.
        DispatchQueue.global().async {
            gate.wait()
            self.respond(server.answer(key: key, path: path, request: self.request, body: body))
        }
    }

    private func respond(_ answer: (status: Int, body: String)) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { gate?.open() }

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

private final class RefreshTestKeychainStore: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppleKeychainItem: Data] = [:]

    func data(for item: AppleKeychainItem) throws -> Data? { lock.withLock { storage[item] } }

    func setData(_ data: Data, for item: AppleKeychainItem) throws { lock.withLock { storage[item] = data } }

    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        lock.withLock {
            if let existing = storage[item] { return existing }
            storage[item] = data
            return data
        }
    }

    func removeData(for item: AppleKeychainItem) throws { lock.withLock { _ = storage.removeValue(forKey: item) } }

    func removeAllData(service: String) throws {
        lock.withLock { storage = storage.filter { $0.key.service != service } }
    }
}
