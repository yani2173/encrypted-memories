import Foundation

/// Optional order evidence from the encrypted metadata. The listing's capture second stays authoritative.
public struct TimelineOrderMetadata: Hashable, Sendable, Codable {
    public let exactCaptureTime: Date?
    public let stableIdentity: String?

    public init(exactCaptureTime: Date? = nil, stableIdentity: String? = nil) {
        self.exactCaptureTime = exactCaptureTime
        self.stableIdentity = stableIdentity?.isEmpty == false ? stableIdentity : nil
    }

    func validated(for captureTime: Date) -> Self? {
        guard let exactCaptureTime,
            exactCaptureTime.timeIntervalSince1970.isFinite,
            floor(exactCaptureTime.timeIntervalSince1970) == floor(captureTime.timeIntervalSince1970)
        else { return nil }
        return self
    }
}
