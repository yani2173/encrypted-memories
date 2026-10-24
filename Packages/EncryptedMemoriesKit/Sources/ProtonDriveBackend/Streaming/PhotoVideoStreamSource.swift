import Foundation
import PhotosCore
import ProtonCoreCryptoGoInterface
import UniformTypeIdentifiers

enum StreamingError: Error, Equatable {
    case noRevision
    case noXAttr
    case revisionPaginationNoProgress
    /// The revision's block list and the XAttr `BlockSizes` disagree on the block count.
    case blockCountMismatch(blockCount: Int, blockSizesCount: Int)
    /// An XAttr block size is negative.
    case negativeBlockSize(Int)
    /// Summing the XAttr block sizes overflowed `Int`.
    case blockSizeSumOverflow
    /// XAttr declares a positive size but the revision lists no blocks.
    case declaredSizeWithoutBlocks(Int)
    /// The summed cleartext block sizes disagree with the declared XAttr size.
    case blockSumSizeMismatch(declared: Int, summed: Int)
    /// A decrypted block has fewer bytes than its validated cleartext size.
    case decryptedBlockLengthMismatch(blockIndex: Int, expected: Int, actual: Int)
    /// A requested byte range maps to a block index that the prepared block map does not contain.
    case missingBlockForSlice(Int)
    /// Fewer cleartext bytes were produced than the validated total.
    case incompleteStream(streamed: Int, expected: Int)
}

/// One block's fetch info + its position in the *cleartext* file (from XAttr block sizes), so the
/// resource loader can map a requested byte range to the blocks it needs.
struct VideoBlock: Sendable {
    let index: Int  // 1-based revision block index (matches the cache key + ClearBlock)
    let url: String  // BareURL (with token) or a pre-signed full URL
    let token: String?  // storage token for the `pm-storage-token` header; nil if `url` is pre-signed
    let clearOffset: Int  // byte offset of this block in the decrypted file
    let clearSize: Int  // decrypted byte length of this block
}

/// Everything needed to serve a streaming video: the item uid (cache key), total size, the per-block
/// map, the content session key, and the content UTI. The session key is a gopenpgp object reused
/// across block decrypts.
final class PreparedVideo: @unchecked Sendable {
    let uid: PhotoUID
    let totalSize: Int
    let contentTypeUTI: String
    let blocks: [VideoBlock]
    let sessionKey: CryptoSessionKey
    /// Pure range-to-slice mapper in cleartext coordinates, shared with the resource loader.
    let blockMap: VideoBlockMap
    private let byIndex: [Int: VideoBlock]

    init(uid: PhotoUID, totalSize: Int, contentTypeUTI: String, blocks: [VideoBlock], sessionKey: CryptoSessionKey) {
        self.uid = uid
        self.totalSize = totalSize
        self.contentTypeUTI = contentTypeUTI
        self.blocks = blocks
        self.sessionKey = sessionKey
        self.blockMap = VideoBlockMap(
            blocks: blocks.map { ClearBlock(index: $0.index, clearOffset: $0.clearOffset, clearSize: $0.clearSize) },
            totalSize: totalSize
        )
        self.byIndex = Dictionary(blocks.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func block(at index: Int) -> VideoBlock? { byIndex[index] }
}

/// Resolves the Drive key chain for a file and prepares its block map for streaming. Caches the
/// share key and node keys, so opening successive videos in the same library only costs the
/// per-file link + revision fetch. All network goes through the authed `DriveSession`.
actor PhotoVideoStreamSource {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private let shareID: String

    private var shareKey: UnlockableKey?
    private var nodeKeyCache: [String: UnlockableKey] = [:]

    init(session: DriveSession, crypto: DriveCrypto, shareID: String) {
        self.session = session
        self.crypto = crypto
        self.shareID = shareID
    }

    /// Resolves keys + block map for the file `uid`. Throws `.notAVideo` if the link isn't a video
    /// (after the full key/XAttr resolve, since the UTI comes from the resolved link), so the viewer
    /// can fall back to the image path.
    func prepare(uid: PhotoUID) async throws -> PreparedVideo {
        let prepared = try await prepareAnyFile(uid: uid)
        guard
            prepared.contentTypeUTI.hasPrefix("public.movie")
                || prepared.contentTypeUTI.hasPrefix("public.video")
                || prepared.contentTypeUTI == "com.apple.quicktime-movie"
                || UTType(prepared.contentTypeUTI)?.conforms(to: .movie) == true
        else {
            throw VideoStreamError.notAVideo
        }
        return prepared
    }

    /// Decrypts the original into RAM without persisting app-owned plaintext. Used by image viewing and
    /// explicit user exports; videos normally use the range-streaming path above.
    func originalData(uid: PhotoUID, onProgress: @Sendable (Double) -> Void) async throws -> Data {
        let prepared = try await prepareAnyFile(uid: uid)
        var out = Data()
        out.reserveCapacity(prepared.totalSize)
        let total = max(prepared.totalSize, 1)
        onProgress(0)
        for block in prepared.blocks {
            try Task.checkCancellation()
            guard block.clearSize > 0 else { continue }
            let encrypted = try await encryptedBlockData(block, priority: .immediate)
            let clear = try crypto.decryptBlock(encrypted, sessionKey: prepared.sessionKey)
            guard clear.count >= block.clearSize else {
                throw StreamingError.decryptedBlockLengthMismatch(
                    blockIndex: block.index, expected: block.clearSize, actual: clear.count)
            }
            out.append(clear.prefix(block.clearSize))
            onProgress(min(1, Double(out.count) / Double(total)))
        }
        guard out.count == prepared.totalSize else {
            throw StreamingError.incompleteStream(streamed: out.count, expected: prepared.totalSize)
        }
        onProgress(1)
        return out
    }

    /// Streams bounded decrypted blocks without aggregating the plaintext original. Viewer decoders consume each
    /// chunk immediately; the legacy `originalData` contract remains for callers that explicitly require `Data`.
    func streamOriginalBytes(
        uid: PhotoUID,
        allowsExpensiveNetwork: Bool = true,
        onChunk: @Sendable (Data) async throws -> Void,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        let prepared = try await prepareAnyFile(uid: uid)
        let total = max(prepared.totalSize, 1)
        var streamed = 0
        onProgress(0)
        for block in prepared.blocks {
            try Task.checkCancellation()
            guard block.clearSize > 0 else { continue }
            let encrypted = try await encryptedBlockData(
                block, priority: .immediate, allowsExpensiveNetwork: allowsExpensiveNetwork)
            let clear = try crypto.decryptBlock(encrypted, sessionKey: prepared.sessionKey)
            guard clear.count >= block.clearSize else {
                throw StreamingError.decryptedBlockLengthMismatch(
                    blockIndex: block.index, expected: block.clearSize, actual: clear.count)
            }
            try await onChunk(Data(clear.prefix(block.clearSize)))
            streamed += block.clearSize
            onProgress(min(1, Double(streamed) / Double(total)))
        }
        guard streamed == prepared.totalSize else {
            throw StreamingError.incompleteStream(streamed: streamed, expected: prepared.totalSize)
        }
        onProgress(1)
    }

    private func prepareAnyFile(uid: PhotoUID) async throws -> PreparedVideo {
        let linkID = uid.nodeID
        let link = try await fetchLink(linkID)
        guard let fp = link.fileProperties, let rev = fp.activeRevision else { throw StreamingError.noRevision }

        let nodeKey = try await nodeKey(for: link)
        let sessionKey = try crypto.contentSessionKey(contentKeyPacketBase64: fp.contentKeyPacket, node: nodeKey)

        let (blockInfos, revXAttr) = try await fetchRevisionBlocks(linkID: linkID, revID: rev.id)
        guard let xattrArmored = link.xAttr ?? revXAttr else { throw StreamingError.noXAttr }
        let xattrData = try crypto.decryptXAttr(xattrArmored, node: nodeKey)
        let xattr = try JSONDecoder().decode(XAttrBody.self, from: xattrData)

        let (blocks, total) = try Self.validatedVideoBlocks(
            blockInfos: blockInfos,
            blockSizes: xattr.common.blockSizes,
            declaredSize: xattr.common.size
        )
        let uti = UTType(mimeType: link.mimeType ?? "") ?? .data
        return PreparedVideo(
            uid: uid, totalSize: total, contentTypeUTI: uti.identifier,
            blocks: blocks, sessionKey: sessionKey)
    }

    /// Validates the block layout and builds the cleared-position block map. A video must never
    /// reach playback with a corrupt layout: mismatched block counts, negative sizes, a positive
    /// declared size with no blocks, or a summed size that disagrees with the declared size are all
    /// typed failures at this seam, before any byte is fetched or decrypted.
    ///
    /// Legacy fallback: when XAttr declares no size (0 or negative), the total falls back to the
    /// summed block sizes, matching the original behavior for older uploads.
    nonisolated static func validatedVideoBlocks(
        blockInfos: [BlockInfo],
        blockSizes: [Int],
        declaredSize: Int
    ) throws -> (blocks: [VideoBlock], totalSize: Int) {
        // Proton's legacy web writer appends a zero remainder even for exact chunk multiples.
        // Extra zero entries describe no bytes; missing sizes or extra nonzero entries are invalid.
        guard blockInfos.count <= blockSizes.count,
            blockSizes.dropFirst(blockInfos.count).allSatisfy({ $0 == 0 })
        else {
            throw StreamingError.blockCountMismatch(
                blockCount: blockInfos.count, blockSizesCount: blockSizes.count)
        }
        for size in blockSizes where size < 0 {
            throw StreamingError.negativeBlockSize(size)
        }

        var sum = 0
        var overflowed = false
        for size in blockSizes {
            let (partial, didOverflow) = sum.addingReportingOverflow(size)
            if didOverflow {
                overflowed = true
                break
            }
            sum = partial
        }
        if overflowed { throw StreamingError.blockSizeSumOverflow }

        if blockInfos.isEmpty {
            if declaredSize > 0 {
                throw StreamingError.declaredSizeWithoutBlocks(declaredSize)
            }
            return (blocks: [], totalSize: 0)
        }

        let total: Int
        if declaredSize > 0 {
            guard declaredSize == sum else {
                throw StreamingError.blockSumSizeMismatch(declared: declaredSize, summed: sum)
            }
            total = declaredSize
        } else {
            total = sum  // legacy fallback: no declared size, use the summed block sizes
        }

        var blocks: [VideoBlock] = []
        blocks.reserveCapacity(blockInfos.count)
        var offset = 0
        let sortedInfos = blockInfos.sorted(by: { $0.index < $1.index })
        for (position, info) in sortedInfos.enumerated() {
            // Contiguous 1-based positions are guaranteed by revision pagination; refuse anything else.
            guard info.index == position + 1 else {
                throw StreamingError.blockCountMismatch(
                    blockCount: blockInfos.count, blockSizesCount: blockSizes.count)
            }
            let clearSize = blockSizes[position]
            let bare = info.bareURL
            blocks.append(
                VideoBlock(
                    index: info.index,
                    url: bare ?? info.url ?? "",
                    token: bare != nil ? info.token : nil,
                    clearOffset: offset,
                    clearSize: clearSize
                ))
            offset = offset + clearSize
        }
        return (blocks: blocks, totalSize: total)
    }

    /// Encrypted bytes for one block - called by the resource loader on demand.
    func encryptedBlockData(
        _ block: VideoBlock,
        priority: ProtonRequestPriority = .immediate,
        priorityHandle: ProtonRequestGovernor.PriorityHandle? = nil,
        allowsExpensiveNetwork: Bool = true
    ) async throws -> Data {
        if priority == .immediate {
            return try await session.requestGovernor.withPriorityScope(
                .immediate,
                // This direct path already supplies `.immediate` to the actual block request.
                // Do not promote unrelated read-ahead that happens to overlap this demand.
                promoting: [],
                suspending: [.storageUpload]
            ) {
                try await session.fetchBlock(
                    url: block.url, token: block.token, priority: priority, priorityHandle: priorityHandle,
                    allowsExpensiveNetwork: allowsExpensiveNetwork)
            }
        }
        return try await session.fetchBlock(
            url: block.url, token: block.token, priority: priority, priorityHandle: priorityHandle,
            allowsExpensiveNetwork: allowsExpensiveNetwork)
    }

    /// Keep upload admission suspended through joining, cache verification and any failed-prefetch retry.
    func withDemandPriority<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await session.requestGovernor.withPriorityScope(
            .immediate, promoting: [], suspending: [.storageUpload]
        ) { try await operation() }
    }

    func promoteDemand(_ priorityHandle: ProtonRequestGovernor.PriorityHandle) async {
        await session.requestGovernor.promote(priorityHandle, to: .immediate)
    }

    /// Fully downloads the clip's encrypted blocks into the shared range cache (no plaintext written anywhere),
    /// so a later streaming play serves entirely from local encrypted bytes. Used after a Live Photo motion
    /// request and before playback starts. Idempotent: skips blocks already cached.
    func prefetchEncrypted(uid: PhotoUID) async throws {
        let cache = VideoByteRangeCache.shared
        let ownerGeneration = cache.captureOwnerGeneration()
        let prepared = try await prepare(uid: uid)
        for block in prepared.blocks {
            try Task.checkCancellation()
            let lookup = await cache.lookupAsync(uid: prepared.uid, block: block.index)
            guard lookup.encrypted == nil else { continue }
            let encrypted = try await encryptedBlockData(block, priority: .immediate)
            _ = await cache.storeAsync(
                uid: prepared.uid,
                block: block.index,
                encrypted: encrypted,
                ticket: lookup.ticket,
                ownerGeneration: ownerGeneration
            )
        }
    }

    // MARK: - Key chain

    private func nodeKey(for link: LinkBody) async throws -> UnlockableKey {
        if let cached = nodeKeyCache[link.linkID] { return cached }
        let parent: UnlockableKey
        if let parentID = link.parentLinkID, !parentID.isEmpty {
            let parentLink = try await fetchLink(parentID)
            parent = try await nodeKey(for: parentLink)
        } else {
            parent = try await shareKeyUnlockable()  // root node: parent key is the ShareKey
        }
        let key = try crypto.unlockNode(key: link.nodeKey, passphrase: link.nodePassphrase, parent: parent)
        nodeKeyCache[link.linkID] = key
        return key
    }

    /// The node key of a link, such as the photos root whose key decrypts the names of its photos.
    func nodeKey(ofLinkID linkID: String) async throws -> UnlockableKey {
        if let cached = nodeKeyCache[linkID] { return cached }
        return try await nodeKey(for: fetchLink(linkID))
    }

    private func shareKeyUnlockable() async throws -> UnlockableKey {
        if let shareKey { return shareKey }
        let boot = try await session.getJSON("/drive/shares/\(shareID)", as: ShareBootstrap.self)
        let key = try crypto.unlockShare(key: boot.key, passphrase: boot.passphrase)
        shareKey = key
        return key
    }

    // MARK: - Endpoints

    private func fetchLink(_ linkID: String) async throws -> LinkBody {
        try await session.getJSON("/drive/shares/\(shareID)/links/\(linkID)", as: LinkResponse.self).link
    }

    /// Pages through the revision's blocks (FromBlockIndex is 1-based) until all are collected.
    private func fetchRevisionBlocks(linkID: String, revID: String) async throws -> ([BlockInfo], String?) {
        let pageSize = 500
        return try await Self.collectRevisionBlocks(pageSize: pageSize) { from in
            let path =
                "/drive/shares/\(self.shareID)/files/\(linkID)/revisions/\(revID)?FromBlockIndex=\(from)&PageSize=\(pageSize)"
            let revision = try await self.session.getJSON(path, as: RevisionResponse.self).revision
            return (blocks: revision.blocks, xAttr: revision.xAttr)
        }
    }

    /// Collects the same pages used by production revision fetching. Keeping the page fetch as a
    /// narrow seam lets tests exercise the loop, terminal-page handling, and cancellation without
    /// constructing the streamer's crypto key chain.
    nonisolated static func collectRevisionBlocks(
        pageSize: Int,
        fetchPage: (Int) async throws -> (blocks: [BlockInfo], xAttr: String?)
    ) async throws -> ([BlockInfo], String?) {
        var all: [BlockInfo] = []
        var xattr: String?
        var from = 1
        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(from)
            try Task.checkCancellation()
            if xattr == nil { xattr = page.xAttr }
            let next = try nextRevisionPageStart(
                previousStart: from,
                blocks: page.blocks,
                pageSize: pageSize
            )
            all.append(contentsOf: page.blocks)
            guard let next else { break }
            from = next
        }
        return (all, xattr)
    }

    /// Every page must contain exactly the contiguous range requested by the 1-based server
    /// cursor. Reordered wire entries are allowed; gaps, duplicates, overlap, cursor skips,
    /// oversized pages, and cursor overflow are unconfirmed pagination.
    nonisolated static func nextRevisionPageStart(
        previousStart: Int,
        blocks: [BlockInfo],
        pageSize: Int
    ) throws -> Int? {
        guard previousStart > 0, pageSize > 0, blocks.count <= pageSize else {
            throw StreamingError.revisionPaginationNoProgress
        }
        guard !blocks.isEmpty else { return nil }

        let lastResult = previousStart.addingReportingOverflow(blocks.count - 1)
        guard !lastResult.overflow else { throw StreamingError.revisionPaginationNoProgress }
        for (offset, index) in blocks.map(\.index).sorted().enumerated() {
            let expected = previousStart + offset
            guard index == expected else { throw StreamingError.revisionPaginationNoProgress }
        }

        guard blocks.count == pageSize else { return nil }
        guard lastResult.partialValue < Int.max else {
            throw StreamingError.revisionPaginationNoProgress
        }
        return lastResult.partialValue + 1
    }
}

// MARK: - Wire models (PascalCase JSON)

private struct ShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case passphrase = "Passphrase"
    }
}

private struct LinkResponse: Decodable {
    let link: LinkBody
    enum CodingKeys: String, CodingKey { case link = "Link" }
}

struct LinkBody: Decodable {
    let linkID: String
    let parentLinkID: String?
    let name: String?
    let mimeType: String?
    let size: Int?
    let nodeKey: String
    let nodePassphrase: String
    let xAttr: String?
    let fileProperties: FileProperties?

    struct FileProperties: Decodable {
        let contentKeyPacket: String
        let activeRevision: ActiveRevision?
        struct ActiveRevision: Decodable {
            let id: String
            /// The revision-level XAttr. For photos uploaded by Proton's own clients the XAttr often
            /// lives only here, not on the link (`prepareAnyFile` needed the same fallback for videos).
            let xAttr: String?
            enum CodingKeys: String, CodingKey {
                case id = "ID"
                case xAttr = "XAttr"
            }
        }
        enum CodingKeys: String, CodingKey {
            case contentKeyPacket = "ContentKeyPacket"
            case activeRevision = "ActiveRevision"
        }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID"
        case parentLinkID = "ParentLinkID"
        case name = "Name"
        case mimeType = "MIMEType"
        case
            size = "Size"
        case nodeKey = "NodeKey"
        case nodePassphrase = "NodePassphrase"
        case xAttr = "XAttr"
        case
            fileProperties = "FileProperties"
    }
}

private struct RevisionResponse: Decodable {
    let revision: RevisionBody
    enum CodingKeys: String, CodingKey { case revision = "Revision" }
    struct RevisionBody: Decodable {
        let blocks: [BlockInfo]
        let xAttr: String?
        enum CodingKeys: String, CodingKey {
            case blocks = "Blocks"
            case xAttr = "XAttr"
        }
    }
}

struct BlockInfo: Decodable {
    let index: Int
    let bareURL: String?
    let url: String?
    let token: String?
    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case bareURL = "BareURL"
        case url = "URL"
        case token = "Token"
    }
}

private struct XAttrBody: Decodable {
    let common: Common
    struct Common: Decodable {
        let size: Int
        let blockSizes: [Int]
        enum CodingKeys: String, CodingKey {
            case size = "Size"
            case blockSizes = "BlockSizes"
        }
    }
    enum CodingKeys: String, CodingKey { case common = "Common" }
}
