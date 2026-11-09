import Foundation
import PhotosCore
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

@Suite("Bounded request trace", .serialized)
struct ProtonRequestTraceTests {
    @Test func traceStorageBudgetStaysBelowTwoMegabytes() {
        let stride = MemoryLayout<RemoteRequestSupportSnapshot.Request>.stride
        let longestCauses = ProtonRequestCause.allCases.map(\.rawValue.utf8.count).sorted(by: >).prefix(3)
        // An inferred cause joins at most three code-owned names, '~', two '+', and '+more'.
        let maximumCauseBytes = longestCauses.reduce(0, +) + 8
        #expect(maximumCauseBytes <= 64)
        // Allow 128 bytes per retained inferred-cause string, including heap/allocator overhead.
        // All other strings are inline or references to the shared code-owned template literals.
        let budget = (stride + 128) * 8_192 + 64
        #expect(budget < 2_000_000)
        print("RequestTraceMemory stride=\(stride) ringBytes=\(stride * 8_192) conservativeBytes=\(budget)")
    }

    @Test func overlappingAccountCallersKeepTheirCausesAndIntervalsInTheExport() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let foreground = try await ProtonAccountInfoRequestCause.foregroundActivation.run {
            try await governor.causes.run(.account) {
                try await governor.acquire(scope: .api, label: .api(method: "GET", path: "/core/v4/users"))
            }
        }
        let settings = try await ProtonAccountInfoRequestCause.visibleSettings.run {
            try await governor.causes.run(.account) {
                try await governor.acquire(scope: .api, label: .api(method: "GET", path: "/core/v4/addresses"))
            }
        }
        try await Task.sleep(for: .milliseconds(2))
        await governor.finish(foreground, statusCode: 200)
        await governor.finish(settings, statusCode: 503)
        // Finishing twice must not create another record.
        await governor.finish(settings, statusCode: 503)
        let report = try await export(governor)
        let records = try #require(report["recentRequests"] as? [[String: Any]])
        #expect(records.count == 2)
        #expect(records.map { $0["cause"] as? String } == ["account.foreground", "account.settings"])
        #expect(records.map { $0["method"] as? String } == ["GET", "GET"])
        #expect(records.map { $0["endpoint"] as? String } == ["/core/v4/users", "/core/v4/addresses"])
        #expect(records.map { $0["status"] as? String } == ["2xx", "5xx"])
        let starts = try records.map { try #require($0["startMilliseconds"] as? Int) }
        let ends = try records.map { try #require($0["endMilliseconds"] as? Int) }
        #expect(starts.allSatisfy { $0 >= 0 })
        #expect(max(starts[0], starts[1]) < min(ends[0], ends[1]))
    }

    @Test func realAccountRefreshPairsOverlapUnderTheTwoCallerScopes() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let admission = JoinedShutdownGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DriveSession(
            session: ProtonSession(
                uid: "fixture", accessToken: "fixture", refreshToken: "fixture", keyPassword: "fixture"),
            store: SessionKeychainStore(service: "request-trace-fixture"),
            accountCacheDirectory: directory, requestGovernor: governor,
            urlProtocolClasses: [HeldAccountTraceProtocol.self])
        HeldAccountTraceProtocol.reset()
        let foreground = Task {
            try await ProtonAccountInfoRequestCause.foregroundActivation.run {
                try await governor.causes.run(.account) {
                    try await admission.withAdmission { _ = try await session.fetchAccountData() }
                }
            }
        }
        let settings = Task {
            try await ProtonAccountInfoRequestCause.visibleSettings.run {
                try await governor.causes.run(.account) {
                    try await admission.withAdmission { _ = try await session.fetchAccountData() }
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while HeldAccountTraceProtocol.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        // Keep both pairs in flight until all four requests have reached the real transport seam.
        #expect(HeldAccountTraceProtocol.count == 4)
        try await Task.sleep(for: .milliseconds(2))
        HeldAccountTraceProtocol.release()
        _ = try await foreground.value
        _ = try await settings.value
        await admission.closeAdmissionAndJoin()
        let snapshot = await governor.requestSupportSnapshot()
        #expect(snapshot.recentRequests.count == 4)
        for cause in ["account.foreground", "account.settings"] {
            let records = snapshot.recentRequests.filter { $0.cause == cause }
            #expect(Set(records.map(\.endpoint)) == ["/core/v4/users", "/core/v4/addresses"])
            #expect(records.allSatisfy { $0.status == "2xx" })
        }
        #expect(
            snapshot.recentRequests.map(\.startMilliseconds).max()!
                < snapshot.recentRequests.map(\.endMilliseconds).min()!)
    }

    @Test func traceTemplatesNeverKeepLowercaseIdentifiersOrUnknownRoutes() {
        #expect(
            ProtonRequestTrace.endpoint(.api(method: "GET", path: "/drive/v2/volumes/private/links/confidential"))
                == "/drive/v2/volumes/{id}/links/{id}")
        #expect(ProtonRequestTrace.endpoint(.api(method: "GET", path: "/unknown/private")) == "<other-api>")
        #expect(ProtonRequestTrace.endpoint(nil) == "<unlabeled>")
    }

    @Test func bulkMetadataRoutesNeverMasqueradeAsSingleNodeReads() {
        for (path, expected) in [
            ("/drive/shares/private/links/fetch_metadata", "/drive/shares/{id}/links/fetch_metadata"),
            ("/drive/volumes/private/trash", "/drive/volumes/{id}/trash"),
            ("/drive/volumes/private/photos/duplicates", "/drive/volumes/{id}/photos/duplicates"),
            ("/drive/photos/volumes/private/links", "/drive/photos/volumes/{id}/links"),
            ("/auth/v4/sessions/forks", "/auth/v4/sessions/forks"),
        ] {
            #expect(ProtonRequestTrace.endpoint(.api(method: "POST", path: path)) == expected)
        }
    }

    @Test func requestsArrivingAfterTheFakeBarrierWasReleasedDoNotHang() async throws {
        HeldAccountTraceProtocol.reset()
        HeldAccountTraceProtocol.release()
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DriveSession(
            session: ProtonSession(
                uid: "fixture", accessToken: "fixture", refreshToken: "fixture", keyPassword: "fixture"),
            store: SessionKeychainStore(service: "request-trace-late-fixture"),
            accountCacheDirectory: directory, requestGovernor: governor,
            urlProtocolClasses: [HeldAccountTraceProtocol.self])
        let completion = TraceTestClock()
        let request = Task {
            let _: TraceEmptyResponse = try await session.getJSON("/core/v4/users", as: TraceEmptyResponse.self)
            completion.value = 1
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while completion.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(completion.value == 1)
        // The RED fake must also be released and joined, so failure does not leave a live request.
        HeldAccountTraceProtocol.release()
        try await request.value
    }

    @Test func tracePreservesCancellationAndTransportStatus() async throws {
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let transport = try await governor.acquire(scope: .api)
        await governor.finish(transport, statusCode: nil)
        let cancelled = try await governor.acquire(scope: .api)
        await governor.finish(cancelled, statusCode: nil, cancelled: true)
        #expect(await governor.requestSupportSnapshot().recentRequests.map(\.status) == ["transport", "cancelled"])
    }

    @Test func onlyTheNewest8192CompletedRequestsRemain() async throws {
        let clock = TraceTestClock()
        let governor = ProtonRequestGovernor(summaryLog: { _ in }, traceNow: { clock.value })
        for index in 0..<8_195 {
            clock.value = Int64(index * 2)
            let permit = try await governor.acquire(
                scope: .storageUpload, label: .storage(method: index < 3 ? "POST" : "PUT"))
            clock.value += 1
            await governor.finish(permit, statusCode: 200)
        }
        let report = try await export(governor)
        let records = try #require(report["recentRequests"] as? [[String: Any]])
        #expect(records.count == 8_192)
        #expect(records.allSatisfy { $0["method"] as? String == "PUT" })
        #expect(records.allSatisfy { $0["endpoint"] as? String == "<storage>" })
        #expect(records.compactMap { $0["startMilliseconds"] as? Int64 } == (3..<8_195).map { Int64($0 * 2) })
        #expect(report["droppedRequestRecords"] as? Int == 3)
        let snapshot = await governor.requestSupportSnapshot()
        #expect(snapshot.counts.map(\.count).reduce(0, +) == 8_195)
    }

    private func export(_ governor: ProtonRequestGovernor) async throws -> [String: Any] {
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        sources.registerRequests(governor)
        let data = try await SupportDiagnosticsExporter.makeJSONData(sources: sources, trail: SupportEventTrail())
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(report["requests"] as? [String: Any])
    }
}

private struct TraceEmptyResponse: Decodable {}

private final class TraceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0
    var value: Int64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class HeldAccountTraceProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var held: [HeldAccountTraceProtocol] = []
    private static var released = false
    static var count: Int { lock.withLock { held.count } }
    static func reset() {
        lock.withLock {
            held.removeAll()
            released = false
        }
    }
    static func release() {
        let requests = lock.withLock {
            let value = held
            held.removeAll()
            released = true
            return value
        }
        for request in requests { request.respond() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let answerNow = Self.lock.withLock {
            if Self.released { return true }
            Self.held.append(self)
            return false
        }
        if answerNow { respond() }
    }
    override func stopLoading() {
        Self.lock.withLock { Self.held.removeAll { $0 === self } }
    }

    private func respond() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: String
        switch url.path {
        case "/core/v4/users": body = "{\"User\":{\"Keys\":[]}}"
        case "/core/v4/addresses": body = "{\"Addresses\":[]}"
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
