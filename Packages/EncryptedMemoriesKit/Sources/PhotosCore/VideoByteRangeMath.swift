import Foundation

/// A half-open byte range `[lower, upper)` into the *cleartext* file. Pure value type so the range
/// bookkeeping of the streaming loader works without AVFoundation or network dependencies.
public struct ByteRange: Equatable, Sendable {
    public var lower: Int  // inclusive
    public var upper: Int  // exclusive

    public init(lower: Int, upper: Int) {
        precondition(lower <= upper, "ByteRange lower must be <= upper")
        self.lower = lower
        self.upper = upper
    }

    public var length: Int { upper - lower }
}

/// One cleartext block of the file: its index plus where its decrypted bytes live in the whole file.
/// (The encrypted bytes are larger due to PGP overhead, but AVFoundation only ever sees cleartext
/// offsets, so the map is expressed entirely in cleartext coordinates.)
public struct ClearBlock: Equatable, Sendable {
    public let index: Int  // 1-based block index (matches Proton's revision block index)
    public let clearOffset: Int  // byte offset of this block's first decrypted byte in the file
    public let clearSize: Int  // decrypted length of this block

    public init(index: Int, clearOffset: Int, clearSize: Int) {
        self.index = index
        self.clearOffset = clearOffset
        self.clearSize = clearSize
    }
}

/// One block's contribution to a requested range: which block to read, and the sub-slice of that
/// block's *decrypted* bytes to hand back. Returned in file order so concatenating the slices yields
/// exactly the requested window with no gaps - the contiguity AVFoundation requires.
public struct BlockSlice: Equatable, Sendable {
    public let blockIndex: Int
    /// Byte range *within the decrypted block* (0-based) to copy out.
    public let inBlock: ByteRange
    /// Where these bytes land in the file (absolute cleartext offset of `inBlock.lower`).
    public let fileOffset: Int

    public init(blockIndex: Int, inBlock: ByteRange, fileOffset: Int) {
        self.blockIndex = blockIndex
        self.inBlock = inBlock
        self.fileOffset = fileOffset
    }
}

/// Maps an arbitrary requested byte range onto the ordered list of block slices that cover it. This
/// is the native equivalent of Proton Drive Web's `blockSizes[]` to block-indices mapping (the legacy
/// `useVideoStreaming` service-worker path): given the cleartext block sizes, a `Range` request is
/// resolved to the specific blocks to download + decrypt and the exact sub-slices to return.
public struct VideoBlockMap: Sendable {
    public let blocks: [ClearBlock]
    public let totalSize: Int

    /// Builds the map from cleartext block sizes (in revision-index order). `totalOverride` prefers
    /// the authoritative size from XAttr; otherwise the summed block sizes are used.
    public init(blockSizes: [(index: Int, clearSize: Int)], totalOverride: Int? = nil) {
        var built: [ClearBlock] = []
        var offset = 0
        for b in blockSizes.sorted(by: { $0.index < $1.index }) {
            built.append(ClearBlock(index: b.index, clearOffset: offset, clearSize: b.clearSize))
            offset += b.clearSize
        }
        self.blocks = built
        let summed = offset
        self.totalSize = (totalOverride.map { $0 > 0 ? $0 : summed }) ?? summed
    }

    public init(blocks: [ClearBlock], totalSize: Int) {
        self.blocks = blocks
        self.totalSize = totalSize
    }

    /// The ordered block slices needed to satisfy a request for `length` bytes starting at `offset`.
    /// Clamps to the file size, skips empty blocks, and returns slices in file order so the loader
    /// can stream `respond(with:)` calls contiguously. An out-of-range request returns `[]`.
    ///
    /// Blocks are stored in ascending `clearOffset` order (so their cleartext *ends* are non-decreasing);
    /// a binary search skips straight to the first block that can overlap the window instead of scanning
    /// every block from the front. The result equals a linear scan of every block.
    public func slices(offset: Int, length: Int) -> [BlockSlice] {
        let reqStart = Swift.max(0, offset)
        let reqEnd = Swift.min(offset + length, totalSize)
        guard reqStart < reqEnd else { return [] }
        var out: [BlockSlice] = []
        var i = firstBlockIndex(endGreaterThan: reqStart)
        while i < blocks.count {
            let block = blocks[i]
            i += 1
            guard block.clearSize > 0 else { continue }
            let bStart = block.clearOffset
            let bEnd = bStart + block.clearSize
            if bStart >= reqEnd { break }  // past the window (blocks are ordered)
            let from = Swift.max(reqStart, bStart) - bStart
            let to = Swift.min(reqEnd, bEnd) - bStart
            if from < to {
                out.append(
                    BlockSlice(
                        blockIndex: block.index,
                        inBlock: ByteRange(lower: from, upper: to),
                        fileOffset: bStart + from))
            }
        }
        return out
    }

    /// Up to `count` non-empty blocks (in file order) whose cleartext bytes extend past `clearOffset` -
    /// the read-ahead set for forward prefetch. Binary-searches to the first candidate so a large block
    /// count isn't rescanned linearly on every range request. Equivalent to
    /// `blocks.filter { $0.clearSize > 0 && $0.clearOffset + $0.clearSize > clearOffset }.prefix(count)`.
    public func forwardBlocks(afterClearOffset clearOffset: Int, count: Int) -> [ClearBlock] {
        guard count > 0 else { return [] }
        var out: [ClearBlock] = []
        var i = firstBlockIndex(endGreaterThan: clearOffset)
        while i < blocks.count, out.count < count {
            let block = blocks[i]
            i += 1
            if block.clearSize > 0 { out.append(block) }
        }
        return out
    }

    /// Index of the first block whose cleartext *end* (`clearOffset + clearSize`) is strictly greater
    /// than `offset` - i.e. the first block that could contain or follow `offset`. Block ends are
    /// non-decreasing, so this is a standard lower-bound binary search.
    func firstBlockIndex(endGreaterThan offset: Int) -> Int {
        var lo = 0
        var hi = blocks.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if blocks[mid].clearOffset + blocks[mid].clearSize > offset {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }
}
