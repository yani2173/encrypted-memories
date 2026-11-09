import Foundation

enum PhotosRootMaterialError: Error { case missingHashKey }

/// Shares only running key resolution. Each service retains its own existing completed material.
actor PhotosRootMaterialResolver {
    struct Material: Sendable {
        let context: PhotosShareContext
        let rootKey: UnlockableKey
        let hashKey: Data
        let preferredAddressID: String?
    }

    private struct Scope: Hashable {
        let session: ObjectIdentifier
        let crypto: ObjectIdentifier
        let volumeID: String
        let shareID: String
        let rootLinkID: String
    }

    private var flights: [Scope: Task<Material, any Error>] = [:]
    private(set) var isClosed = false
    private(set) var waitingCount = 0
    var activeResolutionCount: Int { flights.count }
    private let beforeCompleting: @Sendable () async -> Void

    init(beforeCompleting: @escaping @Sendable () async -> Void = {}) {
        self.beforeCompleting = beforeCompleting
    }

    func resolve(session: DriveSession, crypto: DriveCrypto, context: PhotosShareContext) async throws -> Material {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let scope = Scope(
            session: ObjectIdentifier(session), crypto: ObjectIdentifier(crypto), volumeID: context.volumeID,
            shareID: context.shareID, rootLinkID: context.rootLinkID)
        let task: Task<Material, any Error>
        if let running = flights[scope] {
            task = running
        } else {
            let beforeCompleting = self.beforeCompleting
            task = Task { [weak self] in
                let result: Result<Material, any Error>
                do {
                    let material = try await Self.load(session: session, crypto: crypto, context: context)
                    await beforeCompleting()
                    try Task.checkCancellation()
                    result = .success(material)
                } catch {
                    result = .failure(error)
                }
                await self?.finish(scope)
                return try result.get()
            }
            flights[scope] = task
        }
        // Cancelling a waiter does not cancel the shared fetch. Keep the fetch tracked until it ends,
        // including after every waiter leaves, so the account owner can cancel and join it at shutdown.
        waitingCount += 1
        defer { waitingCount -= 1 }
        return try await task.valueUntilCancelled()
    }

    func shutdown() async {
        isClosed = true
        let running = Array(flights.values)
        running.forEach { $0.cancel() }
        for task in running { _ = await task.result }
    }

    private func finish(_ scope: Scope) { flights.removeValue(forKey: scope) }

    private static func load(
        session: DriveSession, crypto: DriveCrypto, context: PhotosShareContext
    ) async throws -> Material {
        let bootstrap = try await session.getJSON("/drive/shares/\(context.shareID)", as: ShareBootstrap.self)
        let shareKey = try crypto.unlockShare(key: bootstrap.key, passphrase: bootstrap.passphrase)
        let response = try await session.getJSON(
            "/drive/shares/\(context.shareID)/links/\(context.rootLinkID)", as: RootResponse.self)
        guard let hashKey = response.link.folderProperties?.nodeHashKey else {
            throw PhotosRootMaterialError.missingHashKey
        }
        let rootKey = try crypto.unlockNode(
            key: response.link.nodeKey, passphrase: response.link.nodePassphrase, parent: shareKey)
        let decrypted = try crypto.decryptNodeHashKey(hashKey, node: rootKey)
        return Material(
            context: context, rootKey: rootKey, hashKey: Data(decrypted.utf8), preferredAddressID: bootstrap.addressID)
    }
}

private struct ShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    let addressID: String?
    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case passphrase = "Passphrase"
        case addressID = "AddressID"
    }
}

private struct RootResponse: Decodable {
    let link: Link
    enum CodingKeys: String, CodingKey { case link = "Link" }
    struct Link: Decodable {
        let nodeKey: String
        let nodePassphrase: String
        let folderProperties: FolderProperties?
        enum CodingKeys: String, CodingKey {
            case nodeKey = "NodeKey"
            case nodePassphrase = "NodePassphrase"
            case folderProperties = "FolderProperties"
        }
        struct FolderProperties: Decodable {
            let nodeHashKey: String?
            enum CodingKeys: String, CodingKey { case nodeHashKey = "NodeHashKey" }
        }
    }
}
