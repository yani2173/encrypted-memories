import Foundation

/// Adapts the existing persisted validation namespace to the foreground monitor namespace in memory.
/// The validated cursor belongs to the published cache. Only the local revisions come from the cheap probe.
enum LibraryChangeMonitorSeedPolicy {
    private static let inventoryPrefix = "photos-inventory-v2:"

    static func remoteRevision(from validationToken: String) -> String? {
        guard validationToken.hasPrefix(inventoryPrefix) else { return nil }
        return String(validationToken.dropFirst(inventoryPrefix.count))
    }

    static func baseline(validatedRemoteRevision: String, observedMonitorToken: String) -> String {
        guard let suffixStart = observedMonitorToken.range(of: "#media=", options: .backwards)?.lowerBound else {
            return ""
        }
        let suffix = observedMonitorToken[suffixStart...]
        let fields = suffix.dropFirst().split(separator: "#", omittingEmptySubsequences: false)
        guard fields.count == 2,
            fields[1].hasPrefix("order="),
            isRevision(fields[0].dropFirst("media=".count)),
            isRevision(fields[1].dropFirst("order=".count))
        else { return "" }
        return validatedRemoteRevision + String(suffix)
    }

    private static func isRevision(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}
