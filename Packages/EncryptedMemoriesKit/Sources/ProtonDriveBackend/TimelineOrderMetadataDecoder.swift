import Foundation
import PhotosCore

/// Reads independent optional sections. Unsupported client metadata cannot break the existing MIME reconciliation.
struct TimelineOrderMetadataDecoder {
    private let fractional = ISO8601DateFormatter()
    private let standard = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standard.formatOptions = [.withInternetDateTime]
    }

    func decode(_ data: Data) -> TimelineOrderMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TimelineOrderMetadata()
        }
        return decode(camera: object["Camera"] as? [String: Any], source: object["iOS.photos"] as? [String: Any])
    }
    func decode(camera: Data?, source: Data?) -> TimelineOrderMetadata {
        func object(_ data: Data?) -> [String: Any]? {
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        return decode(camera: object(camera), source: object(source))
    }

    private func decode(camera: [String: Any]?, source: [String: Any]?) -> TimelineOrderMetadata {
        let raw = camera?["CaptureTime"] as? String
        let date = raw.flatMap { fractional.date(from: $0) ?? standard.date(from: $0) }
        return TimelineOrderMetadata(exactCaptureTime: date, stableIdentity: source?["ICloudID"] as? String)
    }
}
