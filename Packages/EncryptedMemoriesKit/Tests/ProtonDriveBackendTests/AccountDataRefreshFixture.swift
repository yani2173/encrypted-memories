import AppleSecurityCore
import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// Each fixture owns its URLProtocol route, in-memory Keychain and empty account-cache directory.
/// Unknown requests fail inside URLProtocol; they never reach an external server.
final class AccountDataRefreshFixture: @unchecked Sendable {
    enum RefreshReply: Sendable {
        case http(Int)
        case transport(URLError.Code)
        case malformed
        case missingToken
        case success
    }

    enum Reply {
        case http(Int, String)
        case failure(URLError.Code)
    }

    static let usersPath = "/core/v4/users"
    static let addressesPath = "/core/v4/addresses"
    static let refreshPath = "/auth/v4/refresh"
    static let unauthorizedBody = #"{"Code":401,"Error":"fixture unauthorized"}"#

    let initial: ProtonSession
    let keychain: AccountDataRefreshKeychain
    let store: SessionKeychainStore
    let session: DriveSession
    private let cacheDirectory: URL
    private let host: String
    private let rejectRenewedToken: Bool
    private let rejectedAccountPath: String
    private let lock = NSLock()
    private var refresh: RefreshReply
    private var requests: [(path: String, authorization: String?)] = []

    init(
        refresh: RefreshReply, rejectRenewedToken: Bool = false,
        rejectedAccountPath: String = AccountDataRefreshFixture.usersPath
    ) throws {
        self.refresh = refresh
        self.rejectRenewedToken = rejectRenewedToken
        self.rejectedAccountPath = rejectedAccountPath
        let identifier = UUID().uuidString.lowercased()
        let host = "\(identifier).account-open.invalid"
        self.host = host
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier, isDirectory: true)
        self.cacheDirectory = cacheDirectory
        let initial = ProtonSession(
            uid: "account-refresh-fixture", accessToken: "fixture-expired-access",
            refreshToken: "fixture-original-refresh", keyPassword: "fixture-key")
        self.initial = initial
        let keychain = AccountDataRefreshKeychain()
        self.keychain = keychain
        let store = SessionKeychainStore(
            service: "account-open-fixture-\(identifier)", account: "default", keychain: keychain)
        self.store = store
        try store.save(initial)
        session = DriveSession(
            session: initial, store: store,
            config: ProtonAPIConfig(baseURL: URL(string: "https://\(host)")!),
            accountCacheDirectory: cacheDirectory, urlProtocolClasses: [AccountDataRefreshHTTP.self])
        AccountDataRefreshHTTP.register(self, host: host)
    }

    func close() {
        keychain.observeSaves(nil)
        keychain.observeVerification(nil)
        AccountDataRefreshHTTP.unregister(host: host)
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            do { try FileManager.default.removeItem(at: cacheDirectory) } catch { Issue.record(error) }
        }
    }

    func setRefreshReply(_ reply: RefreshReply) { lock.withLock { refresh = reply } }

    func requestCount(for path: String) -> Int { lock.withLock { requests.filter { $0.path == path }.count } }

    func authorizations(for path: String) -> [String?] {
        lock.withLock { requests.filter { $0.path == path }.map(\.authorization) }
    }

    func failure(_ operation: () async throws -> Void) async -> (any Error)? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    func reply(to request: URLRequest) -> Reply {
        lock.withLock {
            let path = request.url!.path
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            requests.append((path, authorization))
            switch path {
            case Self.refreshPath:
                switch refresh {
                case .http(let status): return .http(status, "{}")
                case .transport(let code): return .failure(code)
                case .malformed: return .http(200, "not JSON")
                case .missingToken: return .http(200, "{}")
                case .success:
                    return .http(
                        200, #"{"AccessToken":"fixture-renewed-access","RefreshToken":"fixture-renewed-refresh"}"#)
                }
            case Self.usersPath, Self.addressesPath:
                let body = path == Self.usersPath ? #"{"User":{"Keys":[]}}"# : #"{"Addresses":[]}"#
                if path != rejectedAccountPath
                    || (!rejectRenewedToken && authorization == "Bearer fixture-renewed-access")
                {
                    return .http(200, body)
                }
                return .http(401, Self.unauthorizedBody)
            case "/drive/tests/open", "/tests/unqualified":
                if !rejectRenewedToken, authorization == "Bearer fixture-renewed-access" {
                    return .http(200, #"{"User":{"Keys":[]}}"#)
                }
                return .http(401, Self.unauthorizedBody)
            default:
                Issue.record("unexpected fixture endpoint: \(path)")
                return .failure(.unsupportedURL)
            }
        }
    }
}

final class AccountDataRefreshHTTP: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: AccountDataRefreshFixture] = [:]

    static func register(_ fixture: AccountDataRefreshFixture, host: String) {
        lock.withLock { fixtures[host] = fixture }
    }

    static func unregister(host: String) { lock.withLock { _ = fixtures.removeValue(forKey: host) } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
            let fixture = Self.lock.withLock({ Self.fixtures[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch fixture.reply(to: request) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class AccountDataRefreshKeychain: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppleKeychainItem: Data] = [:]
    private var rejectsSaves = false
    private var attempts = 0
    private var observer: (@Sendable (Data) throws -> Void)?
    private var verification: (@Sendable () -> Void)?
    private var awaitsVerification = false
    private var verifications = 0

    var saveAttempts: Int { lock.withLock { attempts } }
    var verifiedSaves: Int { lock.withLock { verifications } }

    func rejectSaves() { lock.withLock { rejectsSaves = true } }

    func observeSaves(_ observer: (@Sendable (Data) throws -> Void)?) { lock.withLock { self.observer = observer } }

    func observeVerification(_ observer: (@Sendable () -> Void)?) { lock.withLock { verification = observer } }

    func data(for item: AppleKeychainItem) throws -> Data? {
        let (data, observe) = lock.withLock {
            let observe = awaitsVerification ? verification : nil
            if observe != nil { verifications += 1 }
            awaitsVerification = false
            return (storage[item], observe)
        }
        observe?()
        return data
    }

    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        let observe = lock.withLock { observer }
        try observe?(data)
        try lock.withLock {
            attempts += 1
            if rejectsSaves { throw SessionKeychainError.verificationFailed }
            storage[item] = data
            awaitsVerification = verification != nil
        }
    }

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
