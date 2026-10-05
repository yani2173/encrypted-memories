import CryptoKit
import Foundation
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveSDK
import Testing
import UploadCore

@testable import ProtonDriveBackend

/// The gopenpgp implementation is process-global and injected once (the apps do the same at startup).
private let compoundCryptoReady: Void = {
    injectDefaultCryptoImplementation()
}()

private func makeSession() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("dedupe-compound-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}

extension DriveSessionStubSuite {
    /// The merge of exact duplicates reads the compounds of many photos with few requests.
    @Suite struct ProtonUploadDedupeCompoundTests {
        @Test func manyCompoundsReadWithOnePhotosRequestAndOneMetadataRequest() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let keys = try CompoundKeys()
            StubURLProtocol.reset()
            try routePhotos([
                ("live", ["live-video"]), ("still", []), ("no-digest", []), ("garbled", []),
            ])
            try routeMetadata([
                try keys.file("live", name: "IMG_1.HEIC", sha1: sha1("live")),
                try keys.file("live-video", name: "IMG_1.MOV", sha1: sha1("video"), main: "live"),
                try keys.file("still", name: "IMG_2.JPG", sha1: sha1("still")),
                try keys.file("no-digest", name: "IMG_3.JPG", sha1: nil),
                try keys.file("garbled", name: "IMG_4.JPG", sha1: sha1("garbled"), armoredName: "not armored"),
            ])
            let service = ProtonUploadDedupeService(
                session: makeSession(), crypto: DriveCrypto(addressKeys: [], signers: []),
                photosClient: NoCompoundDuplicates(), contentIndexStore: content,
                material: .init(
                    context: .init(volumeID: "vol1", shareID: "share1", rootLinkID: "root1"), rootKey: keys.root,
                    hashKey: Data(), epoch: "epoch")
            ) { throw UploadError.backend("The test material is resolved") }

            let compounds = try await service.compounds(ofMainLinks: ["still", "live", "no-digest", "garbled", "live"])

            #expect(Set(compounds.keys) == ["live", "still"], "an unreadable photo leaves the others readable")
            #expect(compounds["live"]?.main.contentHash == ProtonPhotoHMAC.hex(message: sha1("live"), key: Data()))
            #expect(compounds["live"]?.related.map(\.linkID) == ["live-video"])
            #expect(
                compounds["live"]?.related.first?.contentHash
                    == ProtonPhotoHMAC.hex(message: sha1("video"), key: Data()))
            #expect(compounds["still"]?.related.isEmpty == true)
            #expect(
                StubURLProtocol.requests().map(\.path) == [
                    "/drive/photos/volumes/vol1/links", "/drive/shares/share1/links/fetch_metadata",
                ])
            #expect(
                try requestedLinkIDs("/drive/photos/volumes/vol1/links") == ["garbled", "live", "no-digest", "still"])
            #expect(
                try requestedLinkIDs("/drive/shares/share1/links/fetch_metadata") == [
                    "garbled", "live", "live-video", "no-digest", "still",
                ])

            // The read of one compound gives the same photo.
            try routeMetadata([try keys.file("still", name: "IMG_2.JPG", sha1: sha1("still"))])
            let read = try await service.compound(ofMainLink: "still")
            let single = try #require(read)
            #expect(single.main.contentHash == compounds["still"]?.main.contentHash)
            #expect(single.main.nameHash == compounds["still"]?.main.nameHash)
        }

        private func sha1(_ seed: String) -> String {
            Insecure.SHA1.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// The Photos metadata of the main photos, each with its related files.
        private func routePhotos(_ photos: [(linkID: String, related: [String])]) throws {
            let links = photos.map { photo -> [String: Any] in
                let details: [String: Any] = [
                    "RelatedPhotosLinkIDs": photo.related, "CaptureTime": 1, "Tags": [] as [Int],
                ]
                return ["Link": ["LinkID": photo.linkID], "Photo": details]
            }
            let body = try JSONSerialization.data(withJSONObject: ["Code": 1000, "Links": links])
            StubURLProtocol.route("POST /drive/photos/volumes/vol1/links", json: String(decoding: body, as: UTF8.self))
        }

        private func routeMetadata(_ links: [[String: Any]]) throws {
            let body = try JSONSerialization.data(withJSONObject: ["Code": 1000, "Links": links])
            StubURLProtocol.route(
                "POST /drive/shares/share1/links/fetch_metadata", json: String(decoding: body, as: UTF8.self))
        }

        /// Every link ID in the requests to `path`, in request order.
        private func requestedLinkIDs(_ path: String) throws -> [String] {
            try StubURLProtocol.requests().filter { $0.path == path }.flatMap { request in
                let body = try #require(request.body)
                let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                return try #require(json["LinkIDs"] as? [String])
            }
        }
    }
}

/// A photos root key and one node key for every file, so the compound read decrypts names and attributes.
private struct CompoundKeys {
    let crypto = DriveCrypto(addressKeys: [], signers: [])
    let root: UnlockableKey
    private let node: UnlockableKey

    init() throws {
        _ = compoundCryptoReady
        root = UnlockableKey(
            armored: try crypto.generateLockedNodeKey(passphrase: "root-pass"), passphrase: "root-pass")
        node = UnlockableKey(
            armored: try crypto.generateLockedNodeKey(passphrase: "node-pass"), passphrase: "node-pass")
    }

    /// The generic metadata of one active file. A nil `sha1` leaves the digest out; `main` makes it a related file.
    func file(
        _ linkID: String, name: String, sha1: String?, main: String? = nil, armoredName: String? = nil
    ) throws -> [String: Any] {
        let digests: [String: Any] = sha1.map { ["SHA1": $0] } ?? [:]
        let attributes = try JSONSerialization.data(withJSONObject: ["Common": ["Digests": digests]])
        let photo: [String: Any] = main.map { ["MainPhotoLinkID": $0] } ?? [:]
        return [
            "LinkID": linkID, "Type": 2, "State": 1, "MIMEType": "image/jpeg",
            "Name": try armoredName ?? crypto.encrypt(text: name, to: root),
            "NodeKey": node.armored,
            "NodePassphrase": try crypto.encrypt(text: node.passphrase, to: root),
            "XAttr": try crypto.encrypt(text: String(decoding: attributes, as: UTF8.self), to: node),
            "FileProperties": ["ActiveRevision": ["Photo": photo]],
        ]
    }
}

/// The SDK's exact duplicate query, which these tests never reach.
private struct NoCompoundDuplicates: SDKPhotoDuplicatesClient {
    func findPhotoDuplicates(name: String, sha1: Data, cancellationToken: UUID) async throws -> [SDKNodeUid] { [] }
    func cancelFindPhotoDuplicates(cancellationToken: UUID) async throws {}
}
