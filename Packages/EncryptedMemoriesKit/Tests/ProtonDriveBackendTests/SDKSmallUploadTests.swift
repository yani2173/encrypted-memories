import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// SDK 0.33.0 sends small files as one buffered multipart request through `requestSmallUpload`.
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

    @Test(arguments: [
        "drive/https://evil.example/v2/shares/photos",
        "drive/http://drive-api.proton.me/v2/shares/photos",
    ])
    func refusesADriveAPIRequestOutsideTheTrustedAPIHost(relativePath: String) async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])

        let result = await makeClient().requestDriveApi(
            method: "GET", relativePath: relativePath, content: Data(), headers: [])

        #expect(throws: (any Error).self) { try result.get() }
        #expect(SmallUploadURLProtocol.requests.isEmpty, "nothing, and no credential, may reach another host")
    }

    @Test func sendsSessionCredentialsWithABlockFetchOnlyToTheTrustedAPIHost() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200, 200])
        let session = makeSession()

        _ = try await session.fetchBlock(url: "https://evil.example/block", token: nil)
        _ = try await session.fetchBlock(url: "https://drive-api.proton.me/block", token: nil)

        let requests = SmallUploadURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.first?.headers["authorization"] == nil)
        #expect(requests.first?.headers["x-pm-uid"] == nil)
        #expect(requests.last?.headers["authorization"] == "Bearer test-access")
        #expect(requests.last?.headers["x-pm-uid"] == "test-uid")
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

    @Test(.timeLimit(.minutes(1)))
    func sharedBufferedExecutorFinishesEachAttemptBeforeAnIndependentRetry() async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [401, 429, 200])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SmallUploadURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let governor = ProtonRequestGovernor()
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.httpBody = multipartBody
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        var received: BufferedHTTPExecutor.Response?
        do {
            received = try await BufferedHTTPExecutor.perform(
                .init(request: request, credentialGeneration: 0),
                urlSession: transport, governor: governor,
                label: .api(method: "POST", path: endpointPath),
                retryOn401: true, retryOn429: true,
                retryAfterRateLimit: { $0 },
                refreshAfterUnauthorized: { attempt in
                    #expect(await governor.snapshot().api.inFlight == 0)
                    var retry = attempt.request
                    retry.setValue("Bearer new-access", forHTTPHeaderField: "Authorization")
                    return .init(request: retry, credentialGeneration: attempt.credentialGeneration + 1)
                })
        } catch {
            Issue.record("The buffered executor failed: \(error)")
        }
        #expect(received?.response.statusCode == 200)
        #expect(received?.data == Data("response".utf8))
        let requests = SmallUploadURLProtocol.uploads
        #expect(requests.map(\.path) == [endpointPath, endpointPath, endpointPath])
        #expect(
            requests.map { $0.headers["authorization"] } == [
                "Bearer test-access", "Bearer new-access", "Bearer new-access",
            ])
        #expect(requests.map(\.body) == [multipartBody, multipartBody, multipartBody])
        await expectBalanced(governor)
        let support = await governor.requestSupportSnapshot()
        #expect(support.scopes.first { $0.scope == "api" }?.peakInFlight == 1)
        #expect(support.counts.reduce(0) { $0 + $1.count } == 3)
        #expect(
            support.counts.allSatisfy {
                $0.method == "POST" && $0.endpoint == "/drive/photos/volumes/fixture/files"
            })
    }

    struct RetryCase: Sendable {
        let statuses: [Int]
        let attempts: Int
        let refreshes: Int
        let finalStatus: Int
        let paths: [String]
    }

    @Test(arguments: [200, 201, 299, 302, 403, 404, 408, 429, 500, 503])
    func bufferedPostKeepsEachResponseMapping(status: Int) async throws {
        let path = "/drive/tests/buffered"
        SmallUploadURLProtocol.reset(uploadStatuses: [status])
        let direct = makeSession()
        do {
            let data = try await direct.send(path, method: "POST")
            #expect((200...299).contains(status))
            #expect(data == Data("response".utf8))
        } catch {
            guard case .apiError(let code, let message)? = error as? ProtonAuthError else {
                Issue.record("Expected the direct HTTP status error")
                return
            }
            #expect(!(200...299).contains(status))
            #expect(code == status)
            #expect(message == "HTTP \(status) for \(path)")
        }
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        await expectBalanced(direct.requestGovernor)

        SmallUploadURLProtocol.reset(uploadStatuses: [status])
        let sdk = makeSession()
        let response = try await makeClient(session: sdk).requestDriveApi(
            method: "POST", relativePath: path, content: Data(), headers: []
        ).get()
        #expect(response.statusCode == status)
        #expect(response.data == Data("response".utf8))
        #expect(
            response.headers.contains {
                $0.0.lowercased() == "content-type" && $0.1.contains("application/json")
            })
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        #expect(SmallUploadURLProtocol.refreshes.isEmpty)
        await expectBalanced(sdk.requestGovernor)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["GET", "HEAD", "POST", "PUT", "DELETE", "get", "head", "post"], [false, true]
    )
    func bufferedRateLimitPoliciesRemainDistinct(method: String, sdk: Bool) async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [429, 200])
        let session = makeSession()
        let retries = sdk ? ["GET", "HEAD"].contains(method.uppercased()) : false
        let result = await bufferedResult(session, sdk: sdk, method: method, safe: false)
        expectResult(result, sdk: sdk, status: retries ? 200 : 429)
        #expect(SmallUploadURLProtocol.uploads.count == (retries ? 2 : 1))
        #expect(SmallUploadURLProtocol.refreshes.isEmpty)
        await expectBalanced(session.requestGovernor)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            RetryCase(
                statuses: [429, 200], attempts: 2, refreshes: 0, finalStatus: 200,
                paths: [
                    "/drive/tests/buffered",
                    "/drive/tests/buffered",
                ]),
            RetryCase(
                statuses: [429, 429, 200], attempts: 2, refreshes: 0, finalStatus: 429,
                paths: [
                    "/drive/tests/buffered",
                    "/drive/tests/buffered",
                ]),
            RetryCase(
                statuses: [401, 200], attempts: 2, refreshes: 1, finalStatus: 200,
                paths: [
                    "/drive/tests/buffered",
                    "/auth/v4/refresh",
                    "/drive/tests/buffered",
                ]),
            RetryCase(
                statuses: [401, 401, 200], attempts: 2, refreshes: 1, finalStatus: 401,
                paths: [
                    "/drive/tests/buffered",
                    "/auth/v4/refresh",
                    "/drive/tests/buffered",
                ]),
            RetryCase(
                statuses: [401, 429, 200], attempts: 3, refreshes: 1, finalStatus: 200,
                paths: [
                    "/drive/tests/buffered",
                    "/auth/v4/refresh",
                    "/drive/tests/buffered",
                    "/drive/tests/buffered",
                ]),
            RetryCase(
                statuses: [429, 401, 200], attempts: 3, refreshes: 1, finalStatus: 200,
                paths: [
                    "/drive/tests/buffered",
                    "/drive/tests/buffered",
                    "/auth/v4/refresh",
                    "/drive/tests/buffered",
                ]),
            RetryCase(
                statuses: [401, 429, 401, 200], attempts: 3, refreshes: 1, finalStatus: 401,
                paths: [
                    "/drive/tests/buffered",
                    "/auth/v4/refresh",
                    "/drive/tests/buffered",
                    "/drive/tests/buffered",
                ]),
            RetryCase(
                statuses: [429, 401, 429, 200], attempts: 3, refreshes: 1, finalStatus: 429,
                paths: [
                    "/drive/tests/buffered",
                    "/drive/tests/buffered",
                    "/auth/v4/refresh",
                    "/drive/tests/buffered",
                ]),
        ],
        [false, true]
    )
    func bufferedRetryBudgetsRemainIndependent(example: RetryCase, sdk: Bool) async throws {
        SmallUploadURLProtocol.reset(
            uploadStatuses: example.statuses,
            refresh: (200, #"{"AccessToken":"new-access","RefreshToken":"new-refresh"}"#)
        )
        let session = makeSession()
        let result = await bufferedResult(
            session, sdk: sdk, method: sdk ? "GET" : "POST", safe: true)
        expectResult(result, sdk: sdk, status: example.finalStatus)
        #expect(SmallUploadURLProtocol.uploads.count == example.attempts)
        #expect(SmallUploadURLProtocol.refreshes.count == example.refreshes)
        #expect(SmallUploadURLProtocol.requests.map(\.path) == example.paths)
        if example.refreshes == 1 {
            let uploads = SmallUploadURLProtocol.uploads
            #expect(uploads.first?.headers["authorization"] == "Bearer test-access")
            #expect(uploads.last?.headers["authorization"] == "Bearer new-access")
        }
        let snapshot = await session.requestGovernor.requestSupportSnapshot()
        let api = try #require(snapshot.scopes.first { $0.scope == "api" })
        #expect(api.peakInFlight == 1, "a rejected attempt ends before its refresh or retry")
        if !sdk {
            let bodies = SmallUploadURLProtocol.uploads.map(\.body)
            let first = try #require(bodies.first)
            let object = try #require(try JSONSerialization.jsonObject(with: first) as? [String: [String]])
            #expect(object["LinkIDs"] == ["fixture"])
            #expect(bodies.allSatisfy { $0 == first })
        }
        await expectBalanced(session.requestGovernor)
    }

    @Test(.timeLimit(.minutes(1)))
    func directJSONReadStillOptsIntoTheRateLimitRetry() async throws {
        struct Answer: Decodable {
            let code: Int
            enum CodingKeys: String, CodingKey { case code = "Code" }
        }
        SmallUploadURLProtocol.reset(
            uploadStatuses: [429, 200], payload: Data(#"{"Code":1000}"#.utf8))
        let session = makeSession()
        let answer = try await session.getJSON("/drive/tests/buffered", as: Answer.self)
        #expect(answer.code == 1000)
        #expect(SmallUploadURLProtocol.uploads.count == 2)
        await expectBalanced(session.requestGovernor)
    }

    @Test(arguments: [false, true])
    func bufferedFailedRefreshReturnsTheOriginalUnauthorizedResult(sdk: Bool) async throws {
        SmallUploadURLProtocol.reset(
            uploadStatuses: [401, 200], refresh: (401, "{}"))
        let session = makeSession()
        let result = await bufferedResult(session, sdk: sdk, method: "GET", safe: true)
        expectResult(result, sdk: sdk, status: 401)
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        #expect(SmallUploadURLProtocol.refreshes.count == 1)
        await expectBalanced(session.requestGovernor)
    }

    @Test(
        arguments: [URLError.timedOut, .networkConnectionLost, .cancelled],
        [false, true]
    )
    func bufferedTransportFailuresReleaseTheirPermitWithoutRetry(
        code: URLError.Code, sdk: Bool
    ) async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200], uploadFailure: code)
        let session = makeSession()
        let result = await bufferedResult(session, sdk: sdk, method: "GET", safe: true)
        guard case .failure(let error) = result else {
            Issue.record("Expected the transport failure")
            return
        }
        let native = error as NSError
        #expect(native.domain == NSURLErrorDomain)
        #expect(native.code == code.rawValue)
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        #expect(SmallUploadURLProtocol.refreshes.isEmpty)
        await expectBalanced(session.requestGovernor)
        let counts = await session.requestGovernor.requestSupportSnapshot().counts
        let status = code == .cancelled ? "cancelled" : "transport"
        #expect(counts.filter { $0.status == status }.reduce(0) { $0 + $1.count } == 1)
    }

    @Test(arguments: [false, true])
    func bufferedNonHTTPResponseReleasesItsPermitAndKeepsTheErrorMapping(sdk: Bool) async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200], nonHTTPResponse: true)
        let session = makeSession()
        let result = await bufferedResult(session, sdk: sdk, method: "GET", safe: true)
        guard case .failure(let error) = result else {
            Issue.record("Expected the non-HTTP response failure")
            return
        }
        if sdk {
            let native = error as NSError
            #expect(native.domain == "EncryptedMemories.SDKHttpClient")
            #expect(native.code == -1)
        } else {
            guard case .invalidResponse? = error as? ProtonAuthError else {
                Issue.record("Expected the direct invalid-response error")
                return
            }
        }
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        await expectBalanced(session.requestGovernor)
    }

    @Test(arguments: [false, true])
    func bufferedQueuedCancellationDispatchesNothing(sdk: Bool) async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])
        let session = makeSession(governor: singlePermitGovernor())
        let governor = session.requestGovernor
        let held = try await governor.acquire(scope: .api)
        var heldReleased = false
        let completion = BufferedCompletion()
        let work = Task {
            let result = await bufferedResult(session, sdk: sdk, method: "GET", safe: true)
            await completion.markFinished()
            return result
        }
        do {
            try #require(
                await waitFor { await governor.snapshot().api.queued == 1 },
                "SETUP: the buffered request must be queued behind the held permit")
            try #require(
                SmallUploadURLProtocol.uploads.isEmpty,
                "SETUP: the queued request must not have reached the transport")
            work.cancel()
            let finishedWhileHeld = await waitFor { await completion.isFinished }
            let stateWhileHeld = await governor.snapshot().api
            await governor.finish(held, statusCode: 200)
            heldReleased = true
            let result = await work.value

            #expect(finishedWhileHeld, "OBSERVATION: cancellation must finish while admission is held")
            #expect(stateWhileHeld.inFlight == 1)
            #expect(stateWhileHeld.queued == 0, "Cancellation must remove the queued waiter")
            #expect(SmallUploadURLProtocol.uploads.isEmpty)
            if case .failure(let error) = result {
                let actual = error as NSError
                let expected = CancellationError() as NSError
                #expect(actual.domain == expected.domain)
                #expect(actual.code == expected.code)
            } else {
                Issue.record("Expected queued cancellation")
            }
            await expectBalanced(governor)
        } catch {
            work.cancel()
            if !heldReleased { await governor.finish(held, statusCode: 200) }
            _ = await work.value
            await expectBalanced(governor)
            throw error
        }
    }

    @Test(arguments: [false, true])
    func bufferedInFlightCancellationFinishesOnlyItsPermit(sdk: Bool) async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200], holdResponses: true)
        let session = makeSession(governor: singlePermitGovernor())
        let governor = session.requestGovernor
        let work = Task {
            await bufferedResult(session, sdk: sdk, method: "GET", safe: true)
        }
        let observed = await waitFor { !SmallUploadURLProtocol.uploads.isEmpty }
        #expect(observed)
        #expect(await governor.snapshot().api.inFlight == 1)
        work.cancel()
        let result = await work.value
        if case .success = result { Issue.record("Expected in-flight cancellation") }
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        await expectBalanced(governor)
    }

    @Test
    func bufferedResponsePassesRetryAfterToTheGovernor() async throws {
        SmallUploadURLProtocol.reset(
            uploadStatuses: [429], responseHeaders: ["Retry-After": "7"])
        let governor = singlePermitGovernor()
        let session = makeSession(governor: governor)
        let response = try await makeClient(session: session).requestSmallUpload(
            method: "POST", url: endpoint, content: multipartBody, metadata: metadata, headers: []
        ).get()
        #expect(response.statusCode == 429)
        #expect(SmallUploadURLProtocol.uploads.count == 1)
        let snapshot = await governor.requestSupportSnapshot()
        let api = try #require(snapshot.scopes.first { $0.scope == "api" })
        #expect(api.maximumRetryAfterSeconds == 7)
        #expect(api.totalCooldownSeconds == 7)
        await expectBalanced(governor)
    }

    @Test(arguments: [false, true])
    func bufferedRequestsKeepImplicitPriorityPromotion(sdk: Bool) async throws {
        SmallUploadURLProtocol.reset(uploadStatuses: [200])
        let session = makeSession(governor: singlePermitGovernor())
        let governor = session.requestGovernor
        let held = try await governor.acquire(scope: .api)
        var heldReleased = false
        let promotion = await governor.beginPriorityScope(
            .immediate, promoting: [.api], suspending: [])
        let competitorCompletion = BufferedCompletion()
        let competitor = Task {
            let result: Result<Bool, any Error>
            do {
                let permit = try await governor.acquire(scope: .api, priority: .userInitiated)
                let requestStarted = !SmallUploadURLProtocol.uploads.isEmpty
                await governor.finish(permit, statusCode: 200)
                result = .success(requestStarted)
            } catch {
                result = .failure(error)
            }
            await competitorCompletion.markFinished()
            return result
        }
        var work: Task<Result<Int, any Error>, Never>?
        do {
            try #require(
                await waitFor { await governor.snapshot().api.queued == 1 },
                "SETUP: the explicit competitor must be queued first")
            let workCompletion = BufferedCompletion()
            let request = Task {
                let result = await bufferedResult(session, sdk: sdk, method: "GET", safe: true)
                await workCompletion.markFinished()
                return result
            }
            work = request
            try #require(
                await waitFor { await governor.snapshot().api.queued == 2 },
                "SETUP: both requests must be queued before admission opens")
            try #require(
                SmallUploadURLProtocol.uploads.isEmpty,
                "SETUP: the held permit must prevent transport dispatch")
            await governor.finish(held, statusCode: 200)
            heldReleased = true
            try #require(
                await waitFor { await workCompletion.isFinished },
                "CLEANUP: the buffered request did not finish")
            try #require(
                await waitFor { await competitorCompletion.isFinished },
                "CLEANUP: the competitor did not finish")
            let result = await request.value
            let competitorResult = await competitor.value
            let promotedRequestWentFirst = try competitorResult.get()
            await governor.endPriorityScope(promotion)

            expectResult(result, sdk: sdk, status: 200)
            #expect(promotedRequestWentFirst, "The promoted request must dispatch before the explicit competitor")
            await expectBalanced(governor)
        } catch {
            work?.cancel()
            competitor.cancel()
            if !heldReleased { await governor.finish(held, statusCode: 200) }
            await governor.endPriorityScope(promotion)
            if let work { _ = await work.value }
            _ = await competitor.value
            await expectBalanced(governor)
            throw error
        }
    }

    private func bufferedResult(
        _ session: DriveSession, sdk: Bool, method: String, safe: Bool
    ) async -> Result<Int, any Error> {
        do {
            if sdk {
                let response = try await makeClient(session: session).requestDriveApi(
                    method: method, relativePath: "/drive/tests/buffered", content: Data(), headers: []
                ).get()
                return .success(response.statusCode)
            }
            _ = try await session.send(
                "/drive/tests/buffered", method: method,
                body: method == "POST" ? ["LinkIDs": ["fixture"]] : nil,
                retryOnRateLimit: safe)
            return .success(200)
        } catch {
            return .failure(error)
        }
    }

    private func expectResult(_ result: Result<Int, any Error>, sdk: Bool, status: Int) {
        switch result {
        case .success(let actual):
            if sdk {
                #expect(actual == status)
            } else {
                #expect((200...299).contains(status))
            }
        case .failure(let error):
            #expect(!sdk, "An SDK HTTP response must remain a status/body result")
            guard case .apiError(let actual, _)? = error as? ProtonAuthError else {
                Issue.record("Expected the direct HTTP status error")
                return
            }
            #expect(actual == status)
            #expect(!(200...299).contains(status))
        }
    }

    private func expectBalanced(_ governor: ProtonRequestGovernor) async {
        let api = await governor.snapshot().api
        #expect(api.inFlight == 0)
        #expect(api.queued == 0)
    }

    private func singlePermitGovernor() -> ProtonRequestGovernor {
        let scope = ProtonRequestGovernor.Configuration.Scope(initialConcurrency: 1, maximumConcurrency: 1)
        return ProtonRequestGovernor(
            configuration: .init(
                api: scope, storageDownload: scope, storageUpload: scope,
                successWindowForIncrease: 32, starvationPromotionInterval: 10))
    }

    private func waitFor(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    private func makeClient(
        expensiveUploadAccess: ExpensiveUploadAccess? = nil, session: DriveSession? = nil
    ) -> SDKHttpClient {
        let session = session ?? makeSession()
        return SDKHttpClient(
            driveSession: session, requestGovernor: session.requestGovernor,
            expensiveUploadAccess: expensiveUploadAccess,
            urlProtocolClasses: [SmallUploadURLProtocol.self])
    }

    private func makeSession(
        governor: ProtonRequestGovernor = ProtonRequestGovernor()
    ) -> DriveSession {
        DriveSession(
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
    }
}

private actor BufferedCompletion {
    private(set) var isFinished = false

    func markFinished() { isFinished = true }
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
    nonisolated(unsafe) private static var payload = Data("response".utf8)
    nonisolated(unsafe) private static var nonHTTPResponse = false
    nonisolated(unsafe) private static var holdResponses = false
    nonisolated(unsafe) private static var responseHeaders: [String: String] = [:]

    static var requests: [Recorded] { lock.withLock { recorded } }
    static var uploads: [Recorded] { requests.filter { $0.path != refreshPath } }
    static var refreshes: [Recorded] { requests.filter { $0.path == refreshPath } }

    static func reset(
        uploadStatuses: [Int],
        uploadFailure: URLError.Code? = nil,
        refresh: (status: Int, json: String) = (401, "{}"),
        redirectLocation: String? = nil,
        payload: Data = Data("response".utf8),
        nonHTTPResponse: Bool = false,
        holdResponses: Bool = false,
        responseHeaders: [String: String] = [:]
    ) {
        lock.withLock {
            self.uploadStatuses = uploadStatuses
            self.uploadFailure = uploadFailure
            self.refresh = refresh
            self.redirectLocation = redirectLocation
            self.payload = payload
            self.nonHTTPResponse = nonHTTPResponse
            self.holdResponses = holdResponses
            self.responseHeaders = responseHeaders
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
            return (status, Self.payload, Self.uploadFailure, Self.redirectLocation)
        }
        let behavior = Self.lock.withLock {
            (Self.nonHTTPResponse, Self.holdResponses, Self.responseHeaders)
        }
        if behavior.1 { return }
        if let failure = outcome.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        if behavior.0 {
            let response = URLResponse(
                url: url, mimeType: nil, expectedContentLength: outcome.body.count,
                textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: outcome.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headerFields = behavior.2
        headerFields["Content-Type"] = "application/json"
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

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
