import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import Testing

@testable import ProtonDriveBackend

/// The gopenpgp implementation is process-global and injected once (the apps do the same at startup).
private let cryptoImplementationReady: Void = {
    injectDefaultCryptoImplementation()
}()

/// A generated Proton key chain covers the address, share, photos-root, and photo-link fields.
/// The fixture decrypts every field sent by the album write service.
private struct AlbumCryptoFixture {
    let crypto: DriveCrypto
    let signer: DriveCryptoSigner
    let shareKey: UnlockableKey
    let rootKey: UnlockableKey
    let rootHashKeyToken: String
    let sharePassphraseMessage: String
    let rootPassphraseMessage: String
    let rootHashKeyMessage: String

    // One uploaded photo, root-parented, as the attach subject.
    let photoName = "IMG_0001.HEIC"
    let photoKeyArmored: String
    let photoPassphraseClear: String
    let photoPassphraseMessage: String
    let photoNameMessage: String
    let photoXAttrMessage: String

    init() throws {
        _ = cryptoImplementationReady
        let boot = DriveCrypto(addressKeys: [], signers: [])

        func makeKey() throws -> UnlockableKey {
            let pass = try boot.randomBase64Token()
            return UnlockableKey(armored: try boot.generateLockedNodeKey(passphrase: pass), passphrase: pass)
        }

        let addressKey = try makeKey()
        signer = DriveCryptoSigner(
            addressID: "addr1",
            addressKeyID: "addr-key-1",
            email: "owner@proton.me",
            key: addressKey
        )
        crypto = DriveCrypto(addressKeys: [addressKey], signers: [signer])

        shareKey = try makeKey()
        sharePassphraseMessage = try crypto.encrypt(text: shareKey.passphrase, to: addressKey)

        rootKey = try makeKey()
        rootPassphraseMessage = try crypto.encrypt(text: rootKey.passphrase, to: shareKey)

        rootHashKeyToken = try boot.randomBase64Token()
        rootHashKeyMessage = try crypto.encrypt(text: rootHashKeyToken, to: rootKey)

        let photoKey = try makeKey()
        photoKeyArmored = photoKey.armored
        photoPassphraseClear = photoKey.passphrase
        photoPassphraseMessage = try crypto.encrypt(text: photoPassphraseClear, to: rootKey)
        photoNameMessage = try crypto.encryptAndSign(text: photoName, to: rootKey, signer: signer)
        photoXAttrMessage = try crypto.encrypt(
            text: #"{"Common":{"Digests":{"SHA1":"abc123"}}}"#,
            to: photoKey
        )
    }

    func makeService() -> ProtonAlbumWriteService {
        ProtonAlbumWriteService(
            session: makeStubbedSession(),
            crypto: crypto
        ) {
            PhotosShareContext(volumeID: "vol1", shareID: "share1", rootLinkID: "root1")
        }
    }

    func routeShareAndRoot() {
        StubURLProtocol.route(
            "GET /drive/shares/share1",
            json: jsonObject([
                "Key": shareKey.armored,
                "Passphrase": sharePassphraseMessage,
                "AddressID": "addr1",
            ]))
        StubURLProtocol.route(
            "GET /drive/shares/share1/links/root1",
            json: jsonObject([
                "Link": [
                    "NodeKey": rootKey.armored,
                    "NodePassphrase": rootPassphraseMessage,
                    "FolderProperties": ["NodeHashKey": rootHashKeyMessage],
                ]
            ]))
    }

    /// HMAC-SHA256 identity hash, byte-identical to the production path.
    func hmacHex(_ message: String, keyToken: String) -> String {
        ProtonPhotoHMAC.hex(message: message, key: Data(keyToken.utf8))
    }

    func decrypt(_ armored: String, with key: UnlockableKey) throws -> String {
        try crypto.decryptArmored(armored, with: [key]).getString()
    }

    func photoMetadata(
        id: String,
        relatedPhotoLinkIDs: [String] = [],
        xAttr: String? = nil
    ) -> [String: Any] {
        var activeRevision: [String: Any] = [:]
        if let xAttr { activeRevision["XAttr"] = xAttr }
        return [
            "Link": [
                "LinkID": id,
                "Name": photoNameMessage,
                "NodeKey": photoKeyArmored,
                "NodePassphrase": photoPassphraseMessage,
            ],
            "Photo": [
                "RelatedPhotosLinkIDs": relatedPhotoLinkIDs,
                "ActiveRevision": activeRevision,
            ],
        ]
    }

    func routePhotoMetadata(_ photos: [[String: Any]]) {
        StubURLProtocol.route(
            "POST /drive/photos/volumes/vol1/links",
            json: jsonObject(["Links": photos])
        )
    }
}

private func makeStubbedSession() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("album-write-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}

private func jsonObject(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func body(of request: StubURLProtocol.Recorded) throws -> [String: Any] {
    let data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private actor AlbumWriteCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didEnter = false

    func wait() async {
        didEnter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

extension DriveSessionStubSuite {
    /// Serialized with every other stub-based suite (process-global URLProtocol route table).
    @Suite struct AlbumWriteServiceTests {
        @Test func createAlbumSendsProtonCompatibleCryptoMaterial() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)

            let service = fixture.makeService()
            let albumID = try await service.createAlbum(name: "Sommer 2026")
            #expect(albumID == "album1")

            let create = try #require(
                StubURLProtocol.requests().first {
                    $0.path == "/drive/photos/volumes/vol1/albums"
                })
            let json = try body(of: create)
            #expect(json["Locked"] as? Bool == false)
            let link = try #require(json["Link"] as? [String: Any])

            // Name: encrypted to the photos root key, decryptable, signed by the address.
            let name = try #require(link["Name"] as? String)
            #expect(try fixture.decrypt(name, with: fixture.rootKey) == "Sommer 2026")
            #expect(link["SignatureEmail"] as? String == "owner@proton.me")

            // Hash: HMAC-SHA256 of the cleartext name keyed with the root hash key.
            #expect(link["Hash"] as? String == fixture.hmacHex("Sommer 2026", keyToken: fixture.rootHashKeyToken))

            // NodePassphrase: decrypts with the root key and unlocks the new NodeKey.
            let nodeKeyArmored = try #require(link["NodeKey"] as? String)
            let passphrase = try fixture.decrypt(try #require(link["NodePassphrase"] as? String), with: fixture.rootKey)
            let albumKey = UnlockableKey(armored: nodeKeyArmored, passphrase: passphrase)
            #expect(throws: Never.self) { _ = try fixture.crypto.unlockedKey(albumKey) }

            // NodePassphraseSignature: detached address-key signature over the passphrase plaintext.
            let signatureArmored = try #require(link["NodePassphraseSignature"] as? String)
            let addressRing = try fixture.crypto.ring([fixture.signer.key])
            var error: NSError?
            let signature = CryptoGo.CryptoNewPGPSignatureFromArmored(signatureArmored, &error)
            #expect(error == nil)
            #expect(throws: Never.self) {
                try addressRing.verifyDetached(
                    CryptoGo.CryptoNewPlainMessageFromString(passphrase), signature: signature, verifyTime: 0
                )
            }

            // NodeHashKey: encrypted to the album's own key.
            let hashKeyMessage = try #require(link["NodeHashKey"] as? String)
            let hashKeyToken = try fixture.decrypt(hashKeyMessage, with: albumKey)
            #expect(!hashKeyToken.isEmpty)

            // Never send plaintext material.
            #expect(link["Name"] as? String != "Sommer 2026")
        }

        @Test func attachReencryptsMetadataToAlbumKeyWithoutMediaUpload() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)
            fixture.routePhotoMetadata([fixture.photoMetadata(id: "p1")])
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: #"""
                    {"Code":1001,"Responses":[{"LinkID":"p1","Response":{"Code":1000}}]}
                    """#)

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Sommer 2026")
            let createRequest = try #require(
                StubURLProtocol.requests().first {
                    $0.path == "/drive/photos/volumes/vol1/albums"
                })
            let albumLink = try #require(try body(of: createRequest)["Link"] as? [String: Any])
            let albumKey = UnlockableKey(
                armored: try #require(albumLink["NodeKey"] as? String),
                passphrase: try fixture.decrypt(
                    try #require(albumLink["NodePassphrase"] as? String), with: fixture.rootKey
                )
            )
            let albumHashKeyToken = try fixture.decrypt(
                try #require(albumLink["NodeHashKey"] as? String), with: albumKey
            )

            let result = try await service.attach(
                [AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: "p1"), sha1Hex: "abc123")],
                albumID: "album1"
            )
            #expect(result.attachedCount == 1)
            #expect(result.failedCount == 0)

            let add = try #require(
                StubURLProtocol.requests().first {
                    $0.path == "/drive/photos/volumes/vol1/albums/album1/add-multiple"
                })
            let albumData = try #require(try body(of: add)["AlbumData"] as? [[String: Any]])
            #expect(albumData.count == 1)
            let entry = try #require(albumData.first)

            #expect(entry["LinkID"] as? String == "p1")
            // Name: re-encrypted to the album key, same cleartext, our signature email.
            let newName = try #require(entry["Name"] as? String)
            #expect(try fixture.decrypt(newName, with: albumKey) == fixture.photoName)
            #expect(newName != fixture.photoNameMessage)
            #expect(entry["NameSignatureEmail"] as? String == "owner@proton.me")
            // Hash + ContentHash: keyed with the album hash key.
            #expect(entry["Hash"] as? String == fixture.hmacHex(fixture.photoName, keyToken: albumHashKeyToken))
            #expect(entry["ContentHash"] as? String == fixture.hmacHex("abc123", keyToken: albumHashKeyToken))
            // NodePassphrase: the same passphrase, re-encrypted to the album key (no media bytes anywhere).
            let newPassphrase = try #require(entry["NodePassphrase"] as? String)
            #expect(try fixture.decrypt(newPassphrase, with: albumKey) == fixture.photoPassphraseClear)
            // Own photos keep their original passphrase signature server-side - none is sent.
            #expect(entry["NodePassphraseSignature"] == nil)
            #expect(entry["SignatureEmail"] == nil)
        }

        @Test func attachSendsLivePhotoRelatedLinksWithTheMainPhoto() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)
            StubURLProtocol.routeSequence(
                "POST /drive/photos/volumes/vol1/links",
                responses: [
                    (
                        200,
                        jsonObject([
                            "Links": [
                                fixture.photoMetadata(id: "live-main", relatedPhotoLinkIDs: ["live-motion"])
                            ]
                        ])
                    ),
                    (
                        200,
                        jsonObject([
                            "Links": [
                                fixture.photoMetadata(id: "live-motion", xAttr: fixture.photoXAttrMessage)
                            ]
                        ])
                    ),
                ]
            )
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: #"{"Code":1001,"Responses":[{"LinkID":"live-main","Response":{"Code":1000}}]}"#
            )

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Live")
            let result = try await service.attach(
                [
                    AlbumAttachRequestItem(
                        uid: PhotoUID(volumeID: "vol1", nodeID: "live-main"),
                        sha1Hex: "abc123"
                    )
                ],
                albumID: "album1"
            )

            #expect(result.attachedCount == 1, "one selected Live Photo remains one logical success")
            let add = try #require(
                StubURLProtocol.requests().first {
                    $0.path == "/drive/photos/volumes/vol1/albums/album1/add-multiple"
                })
            let albumData = try #require(try body(of: add)["AlbumData"] as? [[String: Any]])
            #expect(albumData.compactMap { $0["LinkID"] as? String } == ["live-main", "live-motion"])
            #expect(albumData.allSatisfy { $0["ContentHash"] is String })
        }

        @Test func attachRetriesOnceWithRelatedLinksReportedMissingByTheServer() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)
            StubURLProtocol.routeSequence(
                "POST /drive/photos/volumes/vol1/links",
                responses: [
                    (200, jsonObject(["Links": [fixture.photoMetadata(id: "main")]])),
                    (
                        200,
                        jsonObject([
                            "Links": [
                                fixture.photoMetadata(id: "late-related", xAttr: fixture.photoXAttrMessage)
                            ]
                        ])
                    ),
                ]
            )
            StubURLProtocol.routeSequence(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                responses: [
                    (
                        200,
                        #"{"Code":1001,"Responses":[{"LinkID":"main","Response":{"Code":2000,"Details":{"Missing":["late-related"]}}}]}"#
                    ),
                    (200, #"{"Code":1001,"Responses":[{"LinkID":"main","Response":{"Code":1000}}]}"#),
                ]
            )

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Retry")
            let result = try await service.attach(
                [
                    AlbumAttachRequestItem(
                        uid: PhotoUID(volumeID: "vol1", nodeID: "main"),
                        sha1Hex: "abc123"
                    )
                ],
                albumID: "album1"
            )

            #expect(result.attachedCount == 1)
            let addRequests = StubURLProtocol.requests().filter {
                $0.path == "/drive/photos/volumes/vol1/albums/album1/add-multiple"
            }
            #expect(addRequests.count == 2)
            let retryData = try #require(try body(of: addRequests[1])["AlbumData"] as? [[String: Any]])
            #expect(retryData.compactMap { $0["LinkID"] as? String } == ["main", "late-related"])
        }

        @Test func attachResolvesAccountVolumeAndDigestForAnExactProofLink() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"{"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}"#)
            fixture.routePhotoMetadata([fixture.photoMetadata(id: "proven", xAttr: fixture.photoXAttrMessage)])
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: #"{"Code":1001,"Responses":[{"LinkID":"proven","Response":{"Code":1000}}]}"#)
            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Proof")
            let result = try await service.attach(
                [AlbumAttachRequestItem(uid: PhotoUID(volumeID: "", nodeID: "proven"), sha1Hex: nil)],
                albumID: "album1")
            #expect(result.attachedCount == 1)
            #expect(result.failedCount == 0)
            let requests = StubURLProtocol.requests().filter { $0.path.contains("/add-multiple") }
            #expect(requests.count == 1)
            #expect(requests.first?.path == "/drive/photos/volumes/vol1/albums/album1/add-multiple")
            let payload = try #require(try body(of: requests[0])["AlbumData"] as? [[String: Any]])
            #expect(payload.first?["LinkID"] as? String == "proven")
        }

        @Test func attachBatchesToTheAPILimitAndAggregatesPerItemOutcomes() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)

            // 12 photos: p0…p11 - expect one batch of 10 + one of 2.
            let ids = (0..<12).map { "p\($0)" }
            fixture.routePhotoMetadata(ids.map { fixture.photoMetadata(id: $0, xAttr: fixture.photoXAttrMessage) })
            // Per-item echo: p1 already a member (2500), p2 fails (2000), everything else ok.
            let responses: [[String: Any]] = ids.map { id in
                let code: Int = id == "p1" ? 2500 : (id == "p2" ? 2000 : 1000)
                return ["LinkID": id, "Response": ["Code": code, "Error": code == 2000 ? "boom" : ""]]
            }
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: jsonObject(["Code": 1001, "Responses": responses])
            )

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Batch")
            let result = try await service.attach(
                ids.map { AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: $0), sha1Hex: nil) },
                albumID: "album1"
            )

            let addRequests = StubURLProtocol.requests().filter {
                $0.path == "/drive/photos/volumes/vol1/albums/album1/add-multiple"
            }
            #expect(addRequests.count == 2)
            let firstBatch = try #require(try body(of: addRequests[0])["AlbumData"] as? [[String: Any]])
            let secondBatch = try #require(try body(of: addRequests[1])["AlbumData"] as? [[String: Any]])
            #expect(firstBatch.count == 10)
            #expect(secondBatch.count == 2)

            #expect(result.attachedCount == 10)
            #expect(result.alreadyMemberCount == 1)
            #expect(result.failedCount == 1)
            #expect(result.firstFailureMessage == "boom")
        }

        @Test func attachFailsClosedForUnknownMainOutcomesWithoutAffectingValidGroups() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"{"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}"#
            )
            let ids = ["valid", "nil-response", "missing", "duplicate", "unknown"]
            fixture.routePhotoMetadata(ids.map { fixture.photoMetadata(id: $0, xAttr: fixture.photoXAttrMessage) })
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: #"""
                    {"Code":1001,"Responses":[
                      {"LinkID":"valid","Response":{"Code":1000,"Details":{"Missing":["not-a-retry"]}}},
                      {"LinkID":"nil-response"},
                      {"LinkID":"duplicate","Response":{"Code":1000}},
                      {"LinkID":"duplicate","Response":{"Code":2500}},
                      {"LinkID":"unknown","Response":{"Code":4321,"Error":"server id 77"}}
                    ]}
                    """#
            )

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Strict")
            let result = try await service.attach(
                ids.map { AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: $0), sha1Hex: nil) },
                albumID: "album1"
            )

            #expect(result.attachedCount == 1)
            #expect(result.failedCount == 4)
            let unknown = try #require(result.outcomes["unknown"])
            if case .failed(_, let message) = unknown {
                #expect(message == "unconfirmed album response")
            } else {
                Issue.record("unknown main status was not reported as a failure")
            }
        }

        @Test func attachDoesNotRetrySuccessfulCodesWithMissingDetails() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"{"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}"#
            )
            let ids = ["attached-with-missing", "already-member-with-missing"]
            fixture.routePhotoMetadata(
                ids.map {
                    fixture.photoMetadata(id: $0, xAttr: fixture.photoXAttrMessage)
                })
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: #"""
                    {"Code":1001,"Responses":[
                    {"LinkID":"attached-with-missing","Response":{"Code":1000,"Details":{"Missing":["late"]}}},
                    {"LinkID":"already-member-with-missing","Response":{"Code":2500,"Error":"Already in this album","Details":{"Missing":["late"]}}}
                    ]}
                    """#
            )

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Successful statuses")
            let result = try await service.attach(
                ids.map { AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: $0)) },
                albumID: "album1"
            )

            #expect(result.attachedCount == 1)
            #expect(result.alreadyMemberCount == 1)
            #expect(result.failedCount == 0)
            #expect(StubURLProtocol.requests().filter { $0.path.contains("/add-multiple") }.count == 1)
        }

        @Test func attachFailsWhenMissingRetryStillHasUnknownOutcome() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"{"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}"#
            )
            StubURLProtocol.routeSequence(
                "POST /drive/photos/volumes/vol1/links",
                responses: [
                    (
                        200,
                        jsonObject([
                            "Links": [fixture.photoMetadata(id: "main", xAttr: fixture.photoXAttrMessage)]
                        ])
                    ),
                    (
                        200,
                        jsonObject([
                            "Links": [fixture.photoMetadata(id: "late", xAttr: fixture.photoXAttrMessage)]
                        ])
                    ),
                ]
            )
            StubURLProtocol.routeSequence(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                responses: [
                    (
                        200,
                        #"{"Code":1001,"Responses":[{"LinkID":"main","Response":{"Code":2000,"Details":{"Missing":["late"]}}}]}"#
                    ),
                    (
                        200,
                        #"{"Code":1001,"Responses":[{"LinkID":"main","Response":{"Code":2000,"Details":{"Missing":["late"]}}}]}"#
                    ),
                ]
            )

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Retry failure")
            let result = try await service.attach(
                [AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: "main"), sha1Hex: nil)],
                albumID: "album1"
            )

            #expect(result.attachedCount == 0)
            #expect(result.failedCount == 1)
            #expect(StubURLProtocol.requests().filter { $0.path.contains("/add-multiple") }.count == 2)
        }

        @Test func attachPreparesLargeSelectionInInputOrder() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)

            let ids = (0..<24).map { "large-\($0)" }
            fixture.routePhotoMetadata(ids.map { fixture.photoMetadata(id: $0) })
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: jsonObject([
                    "Code": 1001,
                    "Responses": ids.map {
                        [
                            "LinkID": $0,
                            "Response": ["Code": 1000],
                        ]
                    },
                ])
            )

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Large")
            let result = try await service.attach(
                ids.map {
                    AlbumAttachRequestItem(
                        uid: PhotoUID(volumeID: "vol1", nodeID: $0),
                        sha1Hex: "abc123"
                    )
                },
                albumID: "album1"
            )

            #expect(result.attachedCount == ids.count)
            let addRequests = StubURLProtocol.requests().filter {
                $0.path == "/drive/photos/volumes/vol1/albums/album1/add-multiple"
            }
            #expect(addRequests.count == 3)
            let sentIDs = try addRequests.flatMap { request in
                try #require(try body(of: request)["AlbumData"] as? [[String: Any]])
                    .compactMap { $0["LinkID"] as? String }
            }
            #expect(sentIDs == ids)
        }

        @Test func attachPropagatesCancellationBeforeFetchingOrWriting() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            let service = fixture.makeService()
            let gate = AlbumWriteCancellationGate()
            let task = Task {
                await gate.wait()
                return try await service.attach(
                    [AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: "p1"))],
                    albumID: "album1"
                )
            }

            while await !gate.didEnter {
                await Task.yield()
            }
            task.cancel()
            await gate.release()

            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            #expect(StubURLProtocol.requests().isEmpty)
        }

        @Test func attachReportsMissingLinkMetadataPerItemInsteadOfThrowing() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)
            fixture.routePhotoMetadata([
                fixture.photoMetadata(id: "p1", xAttr: fixture.photoXAttrMessage)
            ])
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: #"""
                    {"Code":1001,"Responses":[{"LinkID":"p1","Response":{"Code":1000}}]}
                    """#)

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "Partial")
            let result = try await service.attach(
                [
                    AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: "p1"), sha1Hex: nil),
                    AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: "missing"), sha1Hex: nil),
                ],
                albumID: "album1"
            )
            #expect(result.attachedCount == 1)
            #expect(result.failedCount == 1)
        }

        @Test func attachWithoutManifestSHA1UsesTheEncryptedRevisionDigest() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums",
                json: #"""
                    {"Code":1000,"Album":{"Link":{"LinkID":"album1"}}}
                    """#)
            fixture.routePhotoMetadata([
                fixture.photoMetadata(id: "p1", xAttr: fixture.photoXAttrMessage)
            ])
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/add-multiple",
                json: #"""
                    {"Code":1001,"Responses":[{"LinkID":"p1","Response":{"Code":1000}}]}
                    """#)

            let service = fixture.makeService()
            _ = try await service.createAlbum(name: "NoSHA")
            _ = try await service.attach(
                [AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: "p1"), sha1Hex: nil)],
                albumID: "album1"
            )
            let add = try #require(
                StubURLProtocol.requests().first {
                    $0.path == "/drive/photos/volumes/vol1/albums/album1/add-multiple"
                })
            let entry = try #require((try body(of: add)["AlbumData"] as? [[String: Any]])?.first)
            let createRequest = try #require(
                StubURLProtocol.requests().first {
                    $0.path == "/drive/photos/volumes/vol1/albums"
                })
            let albumLink = try #require(try body(of: createRequest)["Link"] as? [String: Any])
            let albumKey = UnlockableKey(
                armored: try #require(albumLink["NodeKey"] as? String),
                passphrase: try fixture.decrypt(
                    try #require(albumLink["NodePassphrase"] as? String), with: fixture.rootKey
                )
            )
            let albumHashKeyToken = try fixture.decrypt(
                try #require(albumLink["NodeHashKey"] as? String), with: albumKey
            )
            #expect(entry["ContentHash"] as? String == fixture.hmacHex("abc123", keyToken: albumHashKeyToken))
        }

        @Test func attachToExistingAlbumResolvesAlbumKeyFromItsLink() async throws {
            StubURLProtocol.reset()
            let fixture = try AlbumCryptoFixture()
            fixture.routeShareAndRoot()

            // A pre-existing album (created elsewhere): root-parented key + own hash key.
            let boot = DriveCrypto(addressKeys: [], signers: [])
            let albumPass = try boot.randomBase64Token()
            let albumKey = UnlockableKey(
                armored: try boot.generateLockedNodeKey(passphrase: albumPass), passphrase: albumPass
            )
            let albumPassphraseMessage = try fixture.crypto.encrypt(text: albumPass, to: fixture.rootKey)
            let albumHashToken = try boot.randomBase64Token()
            let albumHashMessage = try fixture.crypto.encrypt(text: albumHashToken, to: albumKey)

            StubURLProtocol.route(
                "GET /drive/shares/share1/links/existing-album",
                json: jsonObject([
                    "Link": [
                        "NodeKey": albumKey.armored,
                        "NodePassphrase": albumPassphraseMessage,
                        "AlbumProperties": ["NodeHashKey": albumHashMessage],
                    ]
                ]))
            fixture.routePhotoMetadata([fixture.photoMetadata(id: "p1")])
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/existing-album/add-multiple",
                json: #"""
                    {"Code":1001,"Responses":[{"LinkID":"p1","Response":{"Code":1000}}]}
                    """#)

            let service = fixture.makeService()
            let result = try await service.attach(
                [AlbumAttachRequestItem(uid: PhotoUID(volumeID: "vol1", nodeID: "p1"), sha1Hex: "ff00")],
                albumID: "existing-album"
            )
            #expect(result.attachedCount == 1)

            let add = try #require(
                StubURLProtocol.requests().first {
                    $0.path == "/drive/photos/volumes/vol1/albums/existing-album/add-multiple"
                })
            let entry = try #require((try body(of: add)["AlbumData"] as? [[String: Any]])?.first)
            // Everything re-keyed to the existing album's material.
            #expect(try fixture.decrypt(try #require(entry["Name"] as? String), with: albumKey) == fixture.photoName)
            #expect(entry["Hash"] as? String == fixture.hmacHex(fixture.photoName, keyToken: albumHashToken))
            #expect(entry["ContentHash"] as? String == fixture.hmacHex("ff00", keyToken: albumHashToken))
        }

        @Test func removeFromAlbumUsesVerifiedEndpointAndTenItemBatches() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "POST /drive/photos/volumes/vol1/albums/album1/remove-multiple",
                json: #"{"Code":1001}"#
            )

            let linkIDs = (1...11).map { "p\($0)" }
            try await makeStubbedSession().removeFromAlbum(
                volumeID: "vol1",
                albumLinkID: "album1",
                linkIDs: linkIDs
            )

            let requests = StubURLProtocol.requests().filter {
                $0.path == "/drive/photos/volumes/vol1/albums/album1/remove-multiple"
            }
            #expect(requests.count == 2)
            #expect(try body(of: requests[0])["LinkIDs"] as? [String] == Array(linkIDs.prefix(10)))
            #expect(try body(of: requests[1])["LinkIDs"] as? [String] == ["p11"])
        }
    }
}
