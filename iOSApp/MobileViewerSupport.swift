import AVFoundation
import PhotoViewerCore
import PhotosCore
import SwiftUI

enum MobileViewerMotionPolicy {
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func duration(_ duration: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : duration
    }
}

/// Geometry of the viewer's bottom safe-area content (the filmstrip rows). The bars themselves are native.
enum MobileViewerBottomLayout {
    static let horizontalPadding: CGFloat = 12

    static func profile(compactLandscape: Bool, sideBySide: Bool) -> ViewerChromeLayoutProfile {
        ViewerChromeLayoutProfile.resolve(sideBySide: sideBySide, compactLandscape: compactLandscape)
    }
}

enum MobileVideoPlaybackIntent {
    static func isActivelyPlaying(_ status: AVPlayer.TimeControlStatus) -> Bool {
        status == .playing
    }

    static func isBuffering(_ status: AVPlayer.TimeControlStatus) -> Bool {
        status == .waitingToPlayAtSpecifiedRate
    }

    static func showsLoadingIndicator(intendsToPlay: Bool, isActivelyPlaying: Bool) -> Bool {
        intendsToPlay && !isActivelyPlaying
    }

    static func reachedEnd(current: Double, duration: Double) -> Bool {
        duration > 0 && current >= duration - 0.05
    }
}

/// Prefers resolved media metadata over the timeline hint.
enum MobileViewerMediaRoute {
    static func isVideo(item: PhotoItem, resolvedKind: MediaKind?) -> Bool {
        resolvedKind == .video || (resolvedKind == nil && item.isVideo)
    }
}

/// Names what a viewer share could not prepare. The items are the photos of the shared decision,
/// counted before their files: a Live Photo or the original of an edited photo is one photo.
enum MobileViewerShareFailureText {
    static func message(
        for items: [PhotoItem], expandedSingleSeries: Bool, resolvedKinds: [PhotoUID: MediaKind]
    ) -> String {
        if expandedSingleSeries { return String(localized: "viewer.share_failed_photos") }
        if items.count == 1, let item = items.first,
            MobileViewerMediaRoute.isVideo(item: item, resolvedKind: resolvedKinds[item.uid])
        {
            return String(localized: "viewer.share_failed_video")
        }
        return String(localized: "viewer.share_failed")
    }
}

/// Identifies Live Photo preparation without tying it to changing viewport geometry.
struct MobileLivePhotoMotionTaskID: Equatable {
    let item: PhotoItem
    let isCurrent: Bool
}

#if DEBUG
    private struct MobileViewerDividedTestKey: EnvironmentKey {
        static let defaultValue: Bool? = nil
    }

    private struct MobileViewerTransportChromeTestKey: EnvironmentKey {
        static let defaultValue: Bool? = nil
    }

    private struct MobileViewerShareProbeTestKey: EnvironmentKey {
        static let defaultValue: MobileViewerShareDecisionProbe? = nil
    }

    /// Records the viewer's share decisions so hosted tests can observe them without reaching
    /// into the private selection controller. Production builds inject nothing and record nothing.
    @MainActor
    final class MobileViewerShareDecisionProbe {
        enum Event: Equatable {
            case shared(nodeIDs: [String], failureMessage: String)
            case burstReadFailed(message: String)
            case burstUnsettled
        }

        private(set) var events: [Event] = []

        func record(_ event: Event) { events.append(event) }
    }

    extension EnvironmentValues {
        var mobileViewerTransportChromeForTesting: Bool? {
            get { self[MobileViewerTransportChromeTestKey.self] }
            set { self[MobileViewerTransportChromeTestKey.self] = newValue }
        }

        /// Injects the system arrangement fact for hosted tests; it does not simulate a native fold.
        var mobileViewerIsDividedForTesting: Bool? {
            get { self[MobileViewerDividedTestKey.self] }
            set { self[MobileViewerDividedTestKey.self] = newValue }
        }

        /// Injects the share-decision recorder used by the hosted viewer wiring tests.
        var mobileViewerShareProbeForTesting: MobileViewerShareDecisionProbe? {
            get { self[MobileViewerShareProbeTestKey.self] }
            set { self[MobileViewerShareProbeTestKey.self] = newValue }
        }
    }
#endif
