import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// Drives the account-data producer into the classifier used by AppModel's Retry decision.
/// This does not instantiate DriveSDKBridge, AppModel or the native error view.
@Suite("Account-data refresh Retry decision", .serialized)
struct AccountDataRefreshRetryTests {
    @Test(arguments: [
        AccountDataRefreshFixture.RefreshReply.http(503), .http(429), .transport(.timedOut),
        .malformed, .missingToken,
    ])
    func aTemporaryOrUnclearRefreshFailureKeepsRetry(reply: AccountDataRefreshFixture.RefreshReply) async throws {
        let fixture = try AccountDataRefreshFixture(refresh: reply)
        defer { fixture.close() }

        let error = try await accountDataFailure(fixture)

        #expect(!LibraryOpenFailurePermanence.isPermanent(error))
        #expect(error.localizedDescription.isEmpty, "the existing library-open title needs no technical detail")
        #expect(fixture.session.current == fixture.initial)
        #expect(fixture.session.authorization().generation == 0)
        #expect(try fixture.store.load() == fixture.initial)
        #expect(fixture.keychain.saveAttempts == 1, "only the initial synthetic session was saved")
    }

    @Test func aRejectedRefreshHidesRetry() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .http(401))
        defer { fixture.close() }

        let error = try await accountDataFailure(fixture)

        #expect(LibraryOpenFailurePermanence.isPermanent(error))
        #expect(fixture.session.current == fixture.initial)
        #expect(try fixture.store.load() == fixture.initial)
    }

    @Test func anAddressesRefreshFailureKeepsRetry() async throws {
        let fixture = try AccountDataRefreshFixture(
            refresh: .http(503), rejectedAccountPath: AccountDataRefreshFixture.addressesPath)
        defer { fixture.close() }

        let error = try await accountDataFailure(fixture)

        #expect(!LibraryOpenFailurePermanence.isPermanent(error))
        #expect(error.localizedDescription.isEmpty)
        #expect(fixture.session.current == fixture.initial)
        #expect(try fixture.store.load() == fixture.initial)
    }

    @Test func a401AfterSuccessfulRefreshHidesRetry() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .success, rejectRenewedToken: true)
        defer { fixture.close() }

        let error = try await accountDataFailure(fixture)

        #expect(LibraryOpenFailurePermanence.isPermanent(error))
        #expect(
            fixture.authorizations(for: AccountDataRefreshFixture.usersPath) == [
                "Bearer fixture-expired-access", "Bearer fixture-renewed-access",
            ])
        #expect(fixture.session.authorization().generation == 1)
        #expect(try fixture.store.load() == fixture.session.current)
    }

    @Test func aFailedSessionSaveKeepsRetryWithoutPublishingCredentials() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .success)
        defer { fixture.close() }
        fixture.keychain.rejectSaves()

        let error = try await accountDataFailure(fixture)

        #expect(!LibraryOpenFailurePermanence.isPermanent(error))
        #expect(fixture.keychain.saveAttempts == 2, "the refresh reached the real session store")
        #expect(fixture.session.current == fixture.initial)
        #expect(fixture.session.authorization().generation == 0)
        #expect(try fixture.store.load() == fixture.initial)
    }

    @Test func aLaterAccountOpenSucceedsWithTheSameSessionAfterATransportFailure() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .transport(.timedOut))
        defer { fixture.close() }
        let error = try await accountDataFailure(fixture)
        #expect(!LibraryOpenFailurePermanence.isPermanent(error))

        fixture.setRefreshReply(.success)
        _ = try await fixture.session.fetchAccountData()

        #expect(fixture.requestCount(for: AccountDataRefreshFixture.refreshPath) == 2)
        #expect(fixture.session.current.accessToken == "fixture-renewed-access")
        #expect(fixture.session.current.refreshToken == "fixture-renewed-refresh")
        #expect(fixture.session.authorization().generation == 1)
        #expect(try fixture.store.load() == fixture.session.current)
        #expect(await fixture.session.cachedAccountData() != nil)
    }

    @Test func credentialsArePersistedBeforePublicationAndAnOldGenerationDoesNotRefreshAgain() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .success)
        defer { fixture.close() }
        fixture.keychain.observeSaves { data in
            let replacement = try JSONDecoder().decode(ProtonSession.self, from: data)
            #expect(replacement.accessToken == "fixture-renewed-access")
            #expect(fixture.session.current == fixture.initial)
            #expect(fixture.session.authorization().generation == 0)
            #expect(try fixture.store.load() == fixture.initial)
        }
        fixture.keychain.observeVerification {
            #expect(fixture.session.current == fixture.initial)
            #expect(fixture.session.authorization().generation == 0)
        }

        _ = try await fixture.session.fetchAccountData()

        #expect(fixture.keychain.saveAttempts == 2)
        #expect(
            fixture.keychain.verifiedSaves == 1,
            "the real session store read back the replacement before publication")
        #expect(try fixture.store.load() == fixture.session.current)
        #expect(fixture.session.authorization().generation == 1)
        #expect(await fixture.session.refreshToken(after: 0))
        #expect(fixture.requestCount(for: AccountDataRefreshFixture.refreshPath) == 1)
    }

    @Test func theSDKStillReceivesTheOriginal401AfterATemporaryRefreshFailure() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .http(503))
        defer { fixture.close() }
        let client = SDKHttpClient(
            driveSession: fixture.session, requestGovernor: fixture.session.requestGovernor,
            urlProtocolClasses: [AccountDataRefreshHTTP.self])

        let response = try await client.requestDriveApi(
            method: "GET", relativePath: "/drive/tests/open", content: Data(), headers: []
        ).get()

        #expect(response.statusCode == 401)
        #expect(response.data == Data(AccountDataRefreshFixture.unauthorizedBody.utf8))
        #expect(fixture.requestCount(for: "/drive/tests/open") == 1)
        #expect(fixture.requestCount(for: AccountDataRefreshFixture.refreshPath) == 1)
        #expect(fixture.session.current == fixture.initial)
    }

    @Test func anOrdinaryJSONRequestKeepsItsExisting401Error() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .http(503))
        defer { fixture.close() }
        let error = try #require(
            await fixture.failure {
                _ = try await fixture.session.getJSON("/tests/unqualified", as: [String: String].self)
            })

        guard case ProtonAuthError.apiError(let code, _) = error else {
            Issue.record("an ordinary JSON request must keep its existing ProtonAuthError")
            return
        }
        #expect(code == 401)
        #expect(fixture.requestCount(for: AccountDataRefreshFixture.refreshPath) == 1)
    }

    @Test func aCancelledAccountOpenDoesNotStartARefreshOrPublishCredentials() async throws {
        let fixture = try AccountDataRefreshFixture(refresh: .success)
        defer { fixture.close() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.failure { _ = try await fixture.session.fetchAccountData() }
        }

        let error = try #require(await task.value)

        #expect(ProtonRequestStatusClass.isCancellation(error))
        #expect(fixture.requestCount(for: AccountDataRefreshFixture.refreshPath) == 0)
        #expect(fixture.session.current == fixture.initial)
        #expect(fixture.session.authorization().generation == 0)
        #expect(try fixture.store.load() == fixture.initial)
    }

    private func accountDataFailure(_ fixture: AccountDataRefreshFixture) async throws -> any Error {
        let error = try #require(await fixture.failure { _ = try await fixture.session.fetchAccountData() })
        #expect(fixture.requestCount(for: AccountDataRefreshFixture.refreshPath) == 1)
        let firstAuthorization = fixture.authorizations(for: AccountDataRefreshFixture.usersPath).first ?? nil
        #expect(firstAuthorization == "Bearer fixture-expired-access")
        #expect(await fixture.session.cachedAccountData() == nil, "the open has no readable account-cache fallback")
        return error
    }
}
