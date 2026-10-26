import PhotosCore

extension MapEmptyState {
    /// The state of an empty Map: being offline wins over every scan phase, because a scan cannot move on without
    /// a connection; otherwise the state follows the phase of the location crawl.
    public init(isOnline: Bool, progress: PhotoLocationScanProgress) {
        guard isOnline else {
            self = .offline
            return
        }
        switch progress.phase {
        case .scanning: self = .scanning(scanned: progress.scanned, total: progress.total)
        case .failed: self = .failed
        case .completed: self = .completed
        case .idle: self = .idle
        }
    }
}
