import Foundation
import PhotosCore

/// Adds no request scheduling or timers. The governor owns this completion-ordered ring.
struct ProtonRequestTrace {
    static let capacity = 8_192
    private var records: [RemoteRequestSupportSnapshot.Request]
    private var oldest = 0
    private(set) var dropped = 0

    init() {
        records = []
        records.reserveCapacity(Self.capacity)
    }

    mutating func append(_ record: RemoteRequestSupportSnapshot.Request) {
        if records.count < Self.capacity {
            records.append(record)
        } else {
            records[oldest] = record
            oldest = (oldest + 1) % Self.capacity
            dropped += 1
        }
    }

    var snapshot: [RemoteRequestSupportSnapshot.Request] {
        Array(records[oldest...]) + Array(records[..<oldest])
    }

    /// Match code-owned route templates, never the shape of an identifier. Unknown routes remain counted.
    /// This deliberately leaves the existing cumulative tally's route-shape heuristic unchanged.
    static func endpoint(_ label: ProtonRequestLabel?) -> String {
        guard let label else { return "<unlabeled>" }
        if label.endpoint == ProtonRequestLabel.storageEndpoint { return ProtonRequestLabel.storageEndpoint }
        let parts = label.endpoint.split(separator: "/")
        return templates.first { template in
            let expected = template.split(separator: "/")
            return parts.count == expected.count
                && zip(parts, expected).allSatisfy { actual, fixed in fixed == "{id}" || actual == fixed }
        } ?? "<other-api>"
    }

    private static let templates = [
        "/core/v4/users", "/core/v4/addresses", "/auth/v4/refresh", "/core/v4/keys/salts",
        "/auth/v4/sessions/forks",
        "/drive/volumes", "/drive/volumes/{id}", "/drive/volumes/{id}/photos",
        "/drive/volumes/{id}/photos/duplicates", "/drive/volumes/{id}/trash",
        "/drive/volumes/{id}/events/latest", "/drive/volumes/{id}/events/{id}",
        "/drive/shares", "/drive/shares/{id}", "/drive/shares/{id}/keys",
        // Fixed actions precede the generic identifier route, including lowercase-only identifier slots.
        "/drive/shares/{id}/links/fetch_metadata",
        "/drive/shares/{id}/links/{id}", "/drive/shares/{id}/links/{id}/revisions/{id}",
        "/drive/shares/{id}/files/{id}/revisions/{id}", "/drive/shares/{id}/folders/{id}/children",
        "/drive/v2/shares/my-files", "/drive/v2/volumes/{id}", "/drive/v2/volumes/{id}/links",
        "/drive/v2/volumes/{id}/links/{id}", "/drive/v2/volumes/{id}/links/{id}/revisions/{id}",
        "/drive/v2/volumes/{id}/trash", "/drive/v2/volumes/{id}/trash_multiple",
        "/drive/v2/volumes/{id}/trash/restore_multiple", "/drive/v2/volumes/{id}/delete_multiple",
        "/drive/photos/volumes", "/drive/photos/volumes/{id}", "/drive/photos/volumes/{id}/albums",
        "/drive/photos/volumes/{id}/albums/{id}", "/drive/photos/volumes/{id}/albums/{id}/children",
        "/drive/photos/volumes/{id}/albums/{id}/add-multiple",
        "/drive/photos/volumes/{id}/albums/{id}/remove-multiple",
        "/drive/photos/volumes/{id}/files", "/drive/photos/volumes/{id}/files/{id}",
        "/drive/photos/volumes/{id}/links", "/drive/photos/volumes/{id}/links/{id}",
        "/drive/blocks", "/drive/files", "/drive/files/{id}", "/drive/files/{id}/revisions",
    ]

    private static let consoleEnabled =
        ProcessInfo.processInfo.environment[PhotoDiagnostics.debugConsoleLogsEnvironmentKey] == "1"

    static func log(_ record: RemoteRequestSupportSnapshot.Request) {
        guard consoleEnabled else { return }
        let fields = [
            "scope": record.scope, "method": record.method, "endpoint": record.endpoint,
            "cause": record.cause, "status": record.status,
            "startMilliseconds": "\(record.startMilliseconds)", "endMilliseconds": "\(record.endMilliseconds)",
        ]
        PhotoDiagnostics.shared.emitDebug("ProtonRequest", fields)
        // devicectl --console captures standard streams, not the unified-log store.
        #if !DEBUG
            let payload = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("[ProtonRequest] \(payload)")
        #endif
    }
}
