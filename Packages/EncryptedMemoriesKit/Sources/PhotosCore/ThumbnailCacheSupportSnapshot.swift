import Foundation

public struct ThumbnailCacheSupportSnapshot: Codable, Equatable, Sendable {
    public enum Availability: Int, Codable, Sendable {
        case complete = 0
        case partial = 1
        case unavailable = 2
    }
    public enum Kind: Int, Codable, Sendable {
        case thumbnail = 0
        case preview = 1
        case original = 2
    }
    public struct Cache: Codable, Equatable, Sendable {
        public let kind: Kind
        public let blobCount: Int
        public let buckets: [Int]
        public let totalMiB: Int64
        public let readErrors: Int

        public init(kind: Kind, blobCount: Int, buckets: [Int], totalMiB: Int64, readErrors: Int) {
            self.kind = kind
            self.blobCount = blobCount
            self.buckets = buckets
            self.totalMiB = totalMiB
            self.readErrors = readErrors
        }
    }

    public let availability: Availability
    public let caches: [Cache]
    public init(availability: Availability, caches: [Cache]) {
        self.availability = availability
        self.caches = caches
    }
    public static let unavailable = Self(availability: .unavailable, caches: [])
}

public protocol ThumbnailCacheSupportSource: AnyObject, Sendable {
    func thumbnailCacheSupportSnapshot(deadline: ContinuousClock.Instant) async -> ThumbnailCacheSupportSnapshot
}
