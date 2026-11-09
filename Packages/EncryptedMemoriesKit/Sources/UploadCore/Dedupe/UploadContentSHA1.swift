import CryptoKit
import Foundation

/// Streaming SHA-1 for upload identity. Proton's photo duplicate semantics compare
/// `HMAC(hex(SHA1(bytes)), photosRootHashKey)`, and the SDK's `expectedSHA1` upload parameter wants
/// the same 20-byte digest - so every upload path needs the raw-content SHA-1 exactly once.
///
/// SHA-1 here is an identity/integrity fingerprint mandated by the Proton protocol, not a security
/// primitive (hence `Insecure.SHA1`). The file is read in fixed-size chunks through a reused
/// buffer - never loaded whole - so hashing a multi-gigabyte video costs O(bufferSize) memory.
public enum UploadContentSHA1 {
    /// 512 KiB: large enough to amortize syscalls on video-sized files, small enough to be
    /// irrelevant to the memory budget of either platform.
    public static let defaultBufferSize = 512 * 1024

    /// The 20-byte SHA-1 digest of the file at `url`, streamed chunk-by-chunk.
    /// Cooperatively cancellable: checks `Task.checkCancellation()` between chunks, so a queue
    /// cancel during the hashing phase aborts within one buffer's worth of work.
    public static func digest(ofFileAt url: URL, bufferSize: Int = defaultBufferSize) throws -> Data {
        guard let stream = InputStream(url: url) else {
            throw UploadError.fileMissing(url.lastPathComponent)
        }
        stream.open()
        defer { stream.close() }
        // A missing or unreadable file does not fail `open()`. It surfaces as an errored stream that
        // would otherwise hash as an empty file (a silently wrong identity).
        if stream.streamStatus == .error {
            throw stream.streamError ?? UploadError.fileMissing(url.lastPathComponent)
        }

        var hasher = Insecure.SHA1()
        let size = max(1, bufferSize)
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            try Task.checkCancellation()
            let read = stream.read(&buffer, maxLength: size)
            if read < 0 {
                throw stream.streamError ?? UploadError.permissionDenied(url.lastPathComponent)
            }
            if read == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw.prefix(read)))
            }
        }
        return Data(hasher.finalize())
    }

    /// Lowercase hex encoding shared by every identity consumer (one formatting truth: a stray
    /// uppercase hex would silently change every content hash).
    public static func hexString(digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Inverse of `hexString` for manifest rows (20-byte digests persisted as 40 hex chars).
    /// Returns nil for anything malformed, which callers treat as "rehash".
    public static func digest(fromHex hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count == 40 else { return nil }
        var out = Data(capacity: 20)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// Incremental SHA-1 accumulator for streamed sources. PhotoKit uses it during hash-only preflight,
/// then rehashes only the small subset materialized for upload so source drift cannot upload bytes
/// under a stale identity.
public final class UploadSHA1Accumulator {
    private var hasher = Insecure.SHA1()

    public init() {}

    public func update(_ data: Data) {
        hasher.update(data: data)
    }

    /// Consumes the accumulator; the 20-byte digest.
    public func finalizeDigest() -> Data {
        Data(hasher.finalize())
    }
}
