import Foundation
import PhotosCore
import ProtonAuth

/// The identifiers shared by every Photos operation after the account's photo volume exists.
struct PhotosShareContext: Sendable, Equatable {
    let volumeID: String
    let shareID: String
    let rootLinkID: String
}

enum PhotosVolumeBootstrapError: LocalizedError {
    case missingSigner
    case creationFailed(underlying: any Error)

    /// One generic text for every creation failure: the screen names no cause and stays retryable.
    var errorDescription: String? {
        switch self {
        case .missingSigner, .creationFailed: L10n.string("error.library_creation_failed")
        }
    }
}

/// Resolves the account's photo root and creates it when a new account has never used Photos.
///
/// This follows Proton Drive iOS' current photo-volume bootstrap contract: generate a share key,
/// generate a root node key and hash key, then create the E2EE volume through
/// `POST /drive/photos/volumes`. One actor-owned task coalesces timeline and backup callers so a
/// first launch cannot issue two create requests.
actor PhotosVolumeBootstrapService {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private var cachedContext: PhotosShareContext?
    private var resolutionTask: Task<PhotosShareContext, any Error>?

    init(session: DriveSession, crypto: DriveCrypto) {
        self.session = session
        self.crypto = crypto
    }

    func resolve() async throws -> PhotosShareContext {
        if let cachedContext { return cachedContext }
        if let resolutionTask {
            let context = try await resolutionTask.value
            try Task.checkCancellation()
            return context
        }

        let session = self.session
        let crypto = self.crypto
        let task = Task {
            if let existing = try await Self.fetchActiveContext(session: session) {
                return existing
            }
            do {
                return try await Self.createContext(session: session, crypto: crypto)
            } catch {
                if Task.isCancelled || ProtonRequestStatusClass.isCancellation(error) { throw error }
                if case .apiError? = error as? ProtonAuthError { throw error }
                throw PhotosVolumeBootstrapError.creationFailed(underlying: error)
            }
        }
        resolutionTask = task
        defer { resolutionTask = nil }

        do {
            let context = try await task.value
            try Task.checkCancellation()
            cachedContext = context
            return context
        } catch {
            throw error
        }
    }

    private static func fetchActiveContext(session: DriveSession) async throws -> PhotosShareContext? {
        let response = try await session.getJSON(
            "/drive/shares?ShareType=4",
            as: PhotosSharesListResponse.self
        )
        guard let share = response.shares.first(where: { $0.state == 1 && $0.locked != true }) else {
            return nil
        }
        return PhotosShareContext(
            volumeID: share.volumeID,
            shareID: share.shareID,
            rootLinkID: share.linkID
        )
    }

    private static func createContext(session: DriveSession, crypto: DriveCrypto) async throws -> PhotosShareContext {
        guard let signer = crypto.signer(preferredAddressID: nil) else {
            throw PhotosVolumeBootstrapError.missingSigner
        }

        let sharePassphrase = try crypto.randomBase64Token()
        let shareKeyArmored = try crypto.generateLockedNodeKey(passphrase: sharePassphrase)
        let shareKey = UnlockableKey(armored: shareKeyArmored, passphrase: sharePassphrase)
        let sharePassphrasePayload = try crypto.encryptWithDetachedSignature(
            text: sharePassphrase,
            to: signer.key,
            signer: signer
        )

        let rootPassphrase = try crypto.randomBase64Token()
        let rootKeyArmored = try crypto.generateLockedNodeKey(passphrase: rootPassphrase)
        let rootKey = UnlockableKey(armored: rootKeyArmored, passphrase: rootPassphrase)
        let rootPassphrasePayload = try crypto.encryptWithDetachedSignature(
            text: rootPassphrase,
            to: shareKey,
            signer: signer
        )
        let rootHashKey = try crypto.encryptAndSign(
            text: crypto.randomBase64Token(),
            to: rootKey,
            signer: signer
        )
        let rootName = try crypto.encryptAndSign(text: "PhotosRoot", to: shareKey, signer: signer)

        let body: [String: Any] = [
            "Share": [
                "AddressID": signer.addressID,
                "AddressKeyID": signer.addressKeyID,
                "Key": shareKeyArmored,
                "Passphrase": sharePassphrasePayload.message,
                "PassphraseSignature": sharePassphrasePayload.signature,
            ],
            "Link": [
                "Name": rootName,
                "NodeKey": rootKeyArmored,
                "NodePassphrase": rootPassphrasePayload.message,
                "NodePassphraseSignature": rootPassphrasePayload.signature,
                "NodeHashKey": rootHashKey,
            ],
        ]

        do {
            let data = try await session.send(
                "/drive/photos/volumes",
                method: "POST",
                body: body
            )
            let response = try JSONDecoder().decode(CreatePhotosVolumeResponse.self, from: data)
            try Task.checkCancellation()
            DebugLog.log("photos bootstrap: created photo volume ✓")
            return response.volume.context
        } catch {
            // Another signed-in client may have won the cross-device creation race. Accept only
            // an active server result; otherwise preserve the original creation failure.
            let creationError = error
            if Task.isCancelled || ProtonRequestStatusClass.isCancellation(creationError) {
                throw CancellationError()
            }
            let existing: PhotosShareContext?
            do {
                existing = try await fetchActiveContext(session: session)
            } catch {
                if Task.isCancelled || ProtonRequestStatusClass.isCancellation(error) { throw CancellationError() }
                existing = nil
            }
            try Task.checkCancellation()
            if let existing { return existing }
            throw creationError
        }
    }
}

private struct PhotosSharesListResponse: Decodable {
    let shares: [Share]

    struct Share: Decodable {
        let shareID: String
        let volumeID: String
        let linkID: String
        let state: Int
        let locked: Bool?

        enum CodingKeys: String, CodingKey {
            case shareID = "ShareID"
            case volumeID = "VolumeID"
            case linkID = "LinkID"
            case state = "State"
            case locked = "Locked"
        }
    }

    enum CodingKeys: String, CodingKey { case shares = "Shares" }
}

private struct CreatePhotosVolumeResponse: Decodable {
    let volume: Volume

    struct Volume: Decodable {
        let volumeID: String
        let share: Share

        struct Share: Decodable {
            let shareID: String
            let linkID: String

            enum CodingKeys: String, CodingKey {
                case shareID = "ShareID"
                case linkID = "LinkID"
            }
        }

        var context: PhotosShareContext {
            PhotosShareContext(volumeID: volumeID, shareID: share.shareID, rootLinkID: share.linkID)
        }

        enum CodingKeys: String, CodingKey {
            case volumeID = "VolumeID"
            case share = "Share"
        }
    }

    enum CodingKeys: String, CodingKey { case volume = "Volume" }
}
