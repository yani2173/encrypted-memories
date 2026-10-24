import Foundation

/// Publishes the two independent reads of the viewer's Info panel: the photo metadata and the album memberships.
/// Both start together; each result is shown as soon as it arrives, so a slow album read never holds back the
/// metadata. A result is dropped when its task was cancelled or the viewer moved to another photo meanwhile.
public enum ViewerInfoPublication {
    @MainActor
    public static func run<Metadata: Sendable, Memberships: Sendable>(
        metadata: @escaping @Sendable () async -> Metadata,
        memberships: @escaping @Sendable () async -> Memberships,
        isCurrent: () -> Bool,
        publishMetadata: (Metadata) -> Void,
        publishMemberships: (Memberships) -> Void
    ) async {
        await withTaskGroup(of: ViewerInfoReadResult<Metadata, Memberships>.self) { group in
            group.addTask { .metadata(await metadata()) }
            group.addTask { .memberships(await memberships()) }
            for await result in group {
                guard !Task.isCancelled, isCurrent() else { continue }
                switch result {
                case .metadata(let value): publishMetadata(value)
                case .memberships(let value): publishMemberships(value)
                }
            }
        }
    }
}

private enum ViewerInfoReadResult<Metadata: Sendable, Memberships: Sendable>: Sendable {
    case metadata(Metadata)
    case memberships(Memberships)
}
