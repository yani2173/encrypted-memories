import Foundation
import PhotosCore

public struct ViewerTitleMetadataResolution: Equatable, Sendable {
    public let metadata: PhotoMetadata?
    public let placeName: String?
    public let metadataLoadFailed: Bool

    public init(metadata: PhotoMetadata?, placeName: String?, metadataLoadFailed: Bool = false) {
        self.metadata = metadata
        self.placeName = placeName
        self.metadataLoadFailed = metadataLoadFailed
    }

    public var metadataLoadState: PhotoMetadataLoadState {
        if let metadata { return .loaded(metadata) }
        return metadataLoadFailed ? .failed : .unavailable
    }
}

public enum ViewerTitleMetadataState: Equatable, Sendable {
    case resolving
    case resolved(ViewerTitleMetadataResolution)

    public var resolution: ViewerTitleMetadataResolution? {
        guard case .resolved(let value) = self else { return nil }
        return value
    }

    /// Reserve the POI headline only when the encrypted location index already proves this photo has GPS.
    /// Unknown and location-less photos show the capture date on line one immediately; nearby GPS photos still
    /// keep stable two-line geometry while reverse geocoding finishes.
    public func shouldReservePlaceNameLine(hasKnownLocation: Bool) -> Bool {
        hasKnownLocation && self == .resolving
    }
}

/// Bounded shared metadata prefetch for viewer titles. Both app shells ask for the current item and its nearby
/// neighbors, so a normal swipe can promote an already-resolved POI without first replacing it with the date.
@MainActor
public final class ViewerTitleMetadataCoordinator {
    private struct ResolutionTask {
        let id: UUID
        let task: Task<ViewerTitleMetadataResolution, Never>
    }

    private let metadataProvider: (any PhotoMetadataProvider)?
    private let placeNameResolver: (any PlaceNameResolving)?
    private let prefetchRadius: Int
    private var states: [PhotoUID: ViewerTitleMetadataState] = [:]
    private var tasks: [PhotoUID: ResolutionTask] = [:]

    public init(
        metadataProvider: (any PhotoMetadataProvider)?,
        placeNameResolver: (any PlaceNameResolving)?,
        prefetchRadius: Int = 2
    ) {
        self.metadataProvider = metadataProvider
        self.placeNameResolver = placeNameResolver
        self.prefetchRadius = max(0, prefetchRadius)
    }

    public func state(for uid: PhotoUID) -> ViewerTitleMetadataState {
        states[uid] ?? .resolving
    }

    public func prepare(items: [PhotoItem], around index: Int) {
        guard !items.isEmpty else {
            cancelAll()
            return
        }
        let boundedIndex = min(max(index, 0), items.count - 1)
        let lower = max(0, boundedIndex - prefetchRadius)
        let upper = min(items.count - 1, boundedIndex + prefetchRadius)
        let retained = Set(items[lower...upper].map(\.uid))

        for uid in tasks.keys where !retained.contains(uid) {
            tasks.removeValue(forKey: uid)?.task.cancel()
        }
        states = states.filter { retained.contains($0.key) }
        for item in items[lower...upper] {
            beginResolutionIfNeeded(for: item)
        }
    }

    public func resolve(_ item: PhotoItem) async -> ViewerTitleMetadataResolution {
        beginResolutionIfNeeded(for: item)
        if let resolution = states[item.uid]?.resolution { return resolution }
        guard let entry = tasks[item.uid] else {
            return ViewerTitleMetadataResolution(metadata: nil, placeName: nil)
        }
        let resolution = await entry.task.value
        complete(resolution, for: item.uid, taskID: entry.id)
        return states[item.uid]?.resolution ?? resolution
    }

    public func cancelAll() {
        for entry in tasks.values { entry.task.cancel() }
        tasks.removeAll(keepingCapacity: false)
        states.removeAll(keepingCapacity: false)
    }

    public func invalidate(_ uid: PhotoUID) {
        tasks.removeValue(forKey: uid)?.task.cancel()
        states[uid] = nil
    }

    private func beginResolutionIfNeeded(for item: PhotoItem) {
        guard states[item.uid] == nil else { return }
        states[item.uid] = .resolving
        guard let metadataProvider else {
            states[item.uid] = .resolved(.init(metadata: nil, placeName: nil))
            return
        }

        let placeNameResolver = self.placeNameResolver
        let task = Task<ViewerTitleMetadataResolution, Never> {
            let metadata: PhotoMetadata
            do {
                metadata = try await metadataProvider.metadata(for: item.uid)
            } catch {
                return .init(metadata: nil, placeName: nil, metadataLoadFailed: !Task.isCancelled)
            }
            guard !Task.isCancelled else { return .init(metadata: nil, placeName: nil) }
            guard metadata.hasLocation,
                let latitude = metadata.latitude,
                let longitude = metadata.longitude,
                let placeNameResolver
            else { return .init(metadata: metadata, placeName: nil) }
            let placeName = await placeNameResolver.placeName(latitude: latitude, longitude: longitude)
            guard !Task.isCancelled else { return .init(metadata: nil, placeName: nil) }
            return .init(metadata: metadata, placeName: placeName)
        }
        let taskID = UUID()
        tasks[item.uid] = ResolutionTask(id: taskID, task: task)
        Task { [weak self] in
            let resolution = await task.value
            self?.complete(resolution, for: item.uid, taskID: taskID)
        }
    }

    private func complete(
        _ resolution: ViewerTitleMetadataResolution,
        for uid: PhotoUID,
        taskID: UUID
    ) {
        guard tasks[uid]?.id == taskID else { return }
        tasks[uid] = nil
        states[uid] = .resolved(resolution)
    }
}
