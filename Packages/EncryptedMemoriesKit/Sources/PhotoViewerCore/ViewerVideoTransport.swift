import Observation
import PhotosCore

/// Presents the existing page's playback values and forwards commands to that page. It owns no player or stream.
@MainActor
@Observable
public final class ViewerVideoTransport {
    public struct Snapshot: Equatable, Sendable {
        public let currentTime: Double
        public let duration: Double
        public let isPlaying: Bool
        public let isLoading: Bool

        public init(currentTime: Double = 0, duration: Double = 0, isPlaying: Bool = false, isLoading: Bool = false) {
            self.currentTime = currentTime
            self.duration = duration
            self.isPlaying = isPlaying
            self.isLoading = isLoading
        }
    }

    public private(set) var uid: PhotoUID?
    public private(set) var snapshot = Snapshot()
    @ObservationIgnored private var attachment: VideoPlaybackAttachmentIdentity?
    @ObservationIgnored private var toggleAction: (() -> Void)?
    @ObservationIgnored private var seekAction: ((Double) -> Void)?

    public init() {}

    public func isAttached(to uid: PhotoUID?) -> Bool { uid != nil && self.uid == uid }

    public func attach(
        uid: PhotoUID, attachment: VideoPlaybackAttachmentIdentity, snapshot: Snapshot,
        onTogglePlayback: @escaping () -> Void, onSeekTo: @escaping (Double) -> Void
    ) {
        self.attachment = attachment
        toggleAction = onTogglePlayback
        seekAction = onSeekTo
        self.snapshot = snapshot
        self.uid = uid
    }

    public func update(_ snapshot: Snapshot, attachment: VideoPlaybackAttachmentIdentity) {
        guard self.attachment == attachment else { return }
        self.snapshot = snapshot
    }

    /// A disappearing neighbour cannot clear the newly current page's transport.
    public func detach(attachment: VideoPlaybackAttachmentIdentity) {
        guard self.attachment == attachment else { return }
        self.attachment = nil
        toggleAction = nil
        seekAction = nil
        uid = nil
        snapshot = Snapshot()
    }

    public func togglePlayback() { toggleAction?() }
    public func seek(to seconds: Double) { seekAction?(seconds) }
}
