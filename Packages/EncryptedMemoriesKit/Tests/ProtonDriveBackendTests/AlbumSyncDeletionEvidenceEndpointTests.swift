import Foundation
import PhotosCore
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

        /// A busy service waits like every other request; it must not use up the retry budget of the photo.
        @Test(arguments: [408, 429, 500, 503])
        func duplicateLookupTurnsABusyServiceIntoARetryableWait(status: Int) async throws {
            let failure = try await duplicateLookupFailure(status: status)
            guard case .retryableBackend(let code, _)? = failure as? UploadCore.UploadError else {
                Issue.record("expected retryableBackend, got \(failure)")
                return
            }
            #expect(code == status)
        }

        @Test(arguments: [400, 404, 422])
        func duplicateLookupKeepsOtherAnswersAsTheyAre(status: Int) async throws {
            let failure = try await duplicateLookupFailure(status: status)
            guard case .apiError(let code, _)? = failure as? ProtonAuthError else {
                Issue.record("expected the unchanged apiError, got \(failure)")
                return
            }
            #expect(code == status)
        }

        private func duplicateLookupFailure(status: Int) async throws -> any Error {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "POST /drive/volumes/vol/photos/duplicates", status: status,
                json: #"{"Code":2028,"Error":"Service answer"}"#)
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
            do {
                _ = try await service.findDuplicates(nameHashes: ["name-hash"])
            } catch {
                #expect(StubURLProtocol.requests().allSatisfy { $0.path == "/drive/volumes/vol/photos/duplicates" })
                return error
            }
            Issue.record("the lookup must fail for HTTP \(status)")
            return CancellationError()
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

        private static let unsupportedEnvelopeCounter = "albumSync.deletionMetadataUnsupportedEnvelope"

        /// Proton's own client reads `Parents` next to `Code` and `Links`; it is the one extra field that is known.
        @Test(arguments: [
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[{"LinkID":"parent","Name":"x"}]}"#,
            // A marker word in a value is not a marker: only keys count.
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2,"Name":"incomplete"}],"Parents":[{"Name":"more"}]}"#,
        ])
        func theKnownEnvelopeKeepsACompleteAnswerCompleteWithoutACount(json: String) async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/shares/share/links/fetch_metadata", json: json)
            let before = PhotoDiagnostics.shared.counter(Self.unsupportedEnvelopeCounter)
            let result = try await session().fetchLinkStateSnapshot(shareID: "share", linkIDs: ["photo", "absent"])
            #expect(result.complete)
            #expect(result.states == ["photo": 2])
            #expect(PhotoDiagnostics.shared.counter(Self.unsupportedEnvelopeCounter) == before)
        }

        /// A top-level field outside `Code`, `Links` and `Parents` has no verified meaning for this endpoint. The answer
        /// stays incomplete, so absence stays unknown, and the cause is counted. A key that only differs in case from a
        /// canonical key is such a field too.
        @Test(arguments: [
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Pagination":{"NextCursor":"next"}}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[],"Details":{"Note":"x"}}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"SomeNewField":1}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"links":[]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"code":1001}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"PARENTS":[]}"#,
        ])
        func anUnsupportedTopLevelFieldMakesTheAnswerIncompleteAndIsCounted(json: String) async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/shares/share/links/fetch_metadata", json: json)
            let before = PhotoDiagnostics.shared.counter(Self.unsupportedEnvelopeCounter)
            let result = try await session().fetchLinkStateSnapshot(shareID: "share", linkIDs: ["photo", "absent"])
            #expect(!result.complete)
            #expect(PhotoDiagnostics.shared.counter(Self.unsupportedEnvelopeCounter) == before + 1)
        }

        /// `Parents` has to be an array of objects; any other value is not the shape that Proton's client reads.
        @Test(arguments: [
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":{}}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":"x"}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":null}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[1]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[{"LinkID":"parent"},null]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[[]]}"#,
        ])
        func aParentsValueThatIsNotAnArrayOfObjectsMakesTheAnswerIncomplete(json: String) async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/shares/share/links/fetch_metadata", json: json)
            let result = try await session().fetchLinkStateSnapshot(shareID: "share", linkIDs: ["photo", "absent"])
            #expect(!result.complete)
        }

        /// A marker counts by its presence, one level down in each object of `Links` and `Parents`.
        @Test(arguments: [
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[{"LinkID":"parent","Incomplete":true}]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[{"LinkID":"parent"},{"more":false}]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2,"Cursor":null}]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"photo","State":2},{"LinkID":"other","State":2,"Truncated":0}]}"#,
        ])
        func aMarkerInAnObjectOfLinksOrParentsMakesTheAnswerIncomplete(json: String) async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route("POST /drive/shares/share/links/fetch_metadata", json: json)
            let result = try await session().fetchLinkStateSnapshot(shareID: "share", linkIDs: ["photo", "other"])
            #expect(!result.complete)
        }

        @Test(arguments: partialAnswerMarkers, ["true", "false", "0", "null"])
        func eachMarkerAsATopLevelFieldMakesTheAnswerIncomplete(marker: String, value: String) async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "POST /drive/shares/share/links/fetch_metadata",
                json: #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"\#(marker)":\#(value)}"#)
            let result = try await session().fetchLinkStateSnapshot(shareID: "share", linkIDs: ["photo"])
            #expect(!result.complete)
        }

        /// The consumer reports a deletion only from a complete answer, so a marker next to a State 2 row reports none.
        @Test func aMarkerNextToADeletedRowReportsNoDeletion() async throws {
            let marked = #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"More":false}"#
            let plain = #"{"Code":1000,"Links":[{"LinkID":"photo","State":2}],"Parents":[]}"#
            let cases: [(json: String, expected: [String: UploadRemoteDeletionState])] = [
                (marked, [:]), (plain, ["photo": .trashed]),
            ]
            for (json, expected) in cases {
                StubURLProtocol.reset()
                StubURLProtocol.route("POST /drive/shares/share/links/fetch_metadata", json: json)
                let manifest = try #require(
                    UploadIdentityManifestStore(
                        url: FileManager.default.temporaryDirectory.appendingPathComponent(
                            UUID().uuidString + ".sqlite")))
                defer { manifest.close() }
                let service = ProtonUploadDedupeService(
                    session: session(), crypto: DriveCrypto(addressKeys: [], signers: []),
                    photosClient: DeletionProbeSDK(), contentIndexStore: manifest,
                    material: .init(
                        context: .init(volumeID: "vol", shareID: "share", rootLinkID: "root"),
                        rootKey: .init(armored: "", passphrase: ""), hashKey: Data(), epoch: "epoch"),
                    contextProvider: { throw UploadError.backend("resolved test material must be reused") })
                let states = try await UploadRemoteDeletionLookup.states(for: ["photo"], checker: service)
                #expect(states == expected)
            }
        }

        @Test(arguments: [
            #"{"Code":1000,"Links":[{"LinkID":"photo"}]}"#,
            #"{"Code":1000,"Links":[{"State":1}]}"#,
            #"{"Code":1000,"Links":[{"LinkID":"unsolicited","State":2}]}"#,
            #"{"Code":1001,"Links":[]}"#,
            #"{"Links":[]}"#,
            #"{"Code":1000,"Links":[],"More":1}"#,
            #"{"Code":1000,"Links":[],"Truncated":true}"#,
            #"{"Code":1000,"Links":[],"NextPage":"2"}"#,
            #"{"Code":1000,"Links":[],"cursor":"abc"}"#,
            #"{"Code":1000,"Links":[],"Parents":[],"INCOMPLETE":1}"#,
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

private let partialAnswerMarkers = [
    "More", "truncated", "INCOMPLETE", "Partial", "NextPage", "nextAnchor", "AnchorID", "Cursor", "continuation",
]

private struct DeletionProbeSDK: SDKPhotoDuplicatesClient {
    var failure: (any Error)? = nil
    func findPhotoDuplicates(name: String, sha1: Data, cancellationToken: UUID) async throws -> [SDKNodeUid] {
        if let failure { throw failure }
        return []
    }
    func cancelFindPhotoDuplicates(cancellationToken: UUID) async throws {}
}
