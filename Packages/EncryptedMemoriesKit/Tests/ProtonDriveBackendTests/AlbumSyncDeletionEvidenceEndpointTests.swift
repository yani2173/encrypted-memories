import Foundation
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

extension DriveSessionStubSuite {
    @Suite struct AlbumSyncDeletionEvidenceEndpointTests {
        private func session() -> DriveSession {
            DriveSession(
                session: ProtonSession(uid: "test", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
                store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
                accountCacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                urlProtocolClasses: [StubURLProtocol.self])
        }

        @Test func strictServiceReadsMetadataWithoutAnActiveIndexRefresh() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/shares/share/links/fetch_metadata", json: #"{"Code":1000,"Links":[]}"#)
            let manifest = try #require(
                UploadIdentityManifestStore(
                    url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")))
            defer { manifest.close() }
            let service = ProtonUploadDedupeService(
                session: session(), crypto: DriveCrypto(addressKeys: [], signers: []),
                photosClient: DeletionProbeSDK(), contentIndexStore: manifest,
                material: .init(
                    context: .init(volumeID: "vol", shareID: "share", rootLinkID: "root"),
                    rootKey: .init(armored: "", passphrase: ""), hashKey: Data(), epoch: "epoch"),
                contextProvider: { throw UploadError.backend("resolved test material must be reused") })
            let metadata = try await service.linkStateSnapshot(of: ["missing"])
            #expect(metadata.complete)
            #expect(
                StubURLProtocol.requests().map(\.path) == [
                    "/drive/shares/share/links/fetch_metadata"
                ])
        }

        @Test func sdkExactLookupPreservesCancellationAndOrdinaryFailureFallback() async throws {
            var errors: [(any Error, Bool)] = [
                (CancellationError(), true), (URLError(.cancelled), true), (UploadError.cancelled, true),
                (UploadError.transport(code: -999, message: "cancelled"), true),
                (UploadError.backend("unavailable"), false),
            ]
            for native in [true, false] {
                for wrapped in [true, false] {
                    var proto = Proton_Drive_Sdk_Error.with {
                        $0.type = native ? "fixture-cancel" : NSURLErrorDomain
                        $0.domain = native ? .successfulCancellation : .network
                        $0.message = "fixture"
                        $0.primaryCode = -999
                    }
                    if wrapped {
                        let inner = proto
                        proto = Proton_Drive_Sdk_Error.with {
                            $0.type = "fixture-outer"
                            $0.domain = .api
                            $0.message = "fixture"
                            $0.innerError = inner
                        }
                    }
                    errors.append((ProtonDriveSDKError(protoError: proto), true))
                }
            }
            for (failure, isCancellation) in errors {
                let manifest = try #require(
                    UploadIdentityManifestStore(
                        url: FileManager.default.temporaryDirectory.appendingPathComponent(
                            UUID().uuidString + ".sqlite")))
                defer { manifest.close() }
                let service = ProtonUploadDedupeService(
                    session: session(), crypto: DriveCrypto(addressKeys: [], signers: []),
                    photosClient: DeletionProbeSDK(failure: failure), contentIndexStore: manifest,
                    material: .init(
                        context: .init(volumeID: "vol", shareID: "share", rootLinkID: "root"),
                        rootKey: .init(armored: "", passphrase: ""), hashKey: Data(), epoch: "epoch"),
                    contextProvider: { throw UploadError.backend("unexpected context lookup") })
                do {
                    let result = try await service.findExactActiveDuplicates(
                        correctedName: "test.heic", sha1Digest: Data(repeating: 7, count: 20))
                    #expect(!isCancellation, "SDK cancellation must not become an empty miss")
                    #expect(result.isEmpty)
                } catch {
                    #expect(isCancellation)
                    #expect(UploadError.isCancellation(error))
                    #expect(!Task.isCancelled)
                }
            }
        }

        @Test func explicitTrashAndCompleteAbsenceKeepTheirRawMeaning() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "POST /drive/shares/share/links/fetch_metadata",
                json: #"{"Code":1000,"Links":[{"LinkID":"trash","State":2}]}"#)
            let result = try await session().fetchLinkStateSnapshot(shareID: "share", linkIDs: ["trash", "absent"])
            #expect(result.complete)
            #expect(result.states == ["trash": 2])
            #expect(StubURLProtocol.requests().count == 1)
        }

        @Test(arguments: [
            #"{"Code":1000,"Links":[{"LinkID":"photo"}]}"#,
            #"{"Code":1000,"Links":[{"State":1}]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"unsolicited","State":2}]}"#,
            #"{"Code":1001,"Links":[]}"#,
            #"{"Links":[]}"#,
            #"{"Code":1000,"Links":[],"More":1}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":1},{"LinkID":"photo","State":2}]}"#,
        ])
        func incompleteMetadataCannotProveAbsence(json: String) async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/shares/share/links/fetch_metadata", json: json)
            let result = try await session().fetchLinkStateSnapshot(shareID: "share", linkIDs: ["photo"])
            #expect(!result.complete)
        }
    }
}

private struct DeletionProbeSDK: SDKPhotoDuplicatesClient {
    var failure: (any Error)? = nil
    func findPhotoDuplicates(name: String, sha1: Data, cancellationToken: UUID) async throws -> [SDKNodeUid] {
        if let failure { throw failure }
        return []
    }
    func cancelFindPhotoDuplicates(cancellationToken: UUID) async throws {}
}
