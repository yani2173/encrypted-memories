import Testing

@testable import MediaByteCache

@Suite struct ThumbnailCacheHexTests {
    @Test func bytesBecomeLowercaseHexWithTwoDigitsEach() {
        #expect(ThumbnailCache.lowercaseHex([UInt8]()) == "")
        #expect(ThumbnailCache.lowercaseHex([0x00, 0x0f, 0xab, 0xff] as [UInt8]) == "000fabff")
    }
}
