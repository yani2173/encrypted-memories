import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// The SDK client never reads a cached response, so its production session must not write the
/// system URL cache or keep cookies in the shared, disk-backed cookie store (#605).
struct SDKHttpClientSessionStorageTests {
    @Test func productionSessionKeepsNoURLCacheAndNoSharedCookieStorage() throws {
        let governor = ProtonRequestGovernor()
        let driveSession = DriveSession(
            session: ProtonSession(
                uid: "test-uid", accessToken: "test-access", refreshToken: "test-refresh", keyPassword: "test-key"),
            store: SessionKeychainStore(
                service: "at.oncloud.encryptedmemories.tests.session-storage-\(UUID().uuidString)"),
            accountCacheDirectory: FileManager.default.temporaryDirectory,
            requestGovernor: governor
        )

        let configuration = SDKHttpClient(driveSession: driveSession, requestGovernor: governor)
            .urlSession.configuration

        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        let cookies = try #require(configuration.httpCookieStorage)
        #expect(cookies !== HTTPCookieStorage.shared)
        #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
    }
}
