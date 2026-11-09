import Foundation

/// Explicit lifecycle of the full-screen video path. The viewer drives the UI from this instead of
/// inferring "is it loading?" from a tangle of optionals, so a stuck spinner or a silent black frame
/// becomes an observable, loggable state with a reason.
///
/// The cardinal rule (mirrors Proton Drive Web's `isLoading` + broken-video guards): a video is
/// always in exactly one of - preparing, buffering *with a real reason*, playing, or failed *with a
/// readable error*. There is no path that leaves the UI loading forever.
public enum VideoViewerState: Equatable, Sendable {
    case idle  // not a video / nothing to play yet
    case resolving  // fetching the link + keys, deciding stream vs download
    case preparingStream  // building the AVURLAsset + resource loader for range streaming
    case downloading(Double)  // full-download fallback in progress (0…1)
    case buffering(Double?)  // player exists but is waiting on bytes (streaming stall / initial fill)
    case ready  // a playable AVPlayer exists, awaiting first frame
    case playing  // AVPlayer.timeControlStatus reached .playing
    case seeking  // user scrubbed; waiting for the new position to buffer
    case failed(VideoPlaybackError)  // gave up - message is shown to the user + logged

    public var label: String {
        switch self {
        case .idle: return "idle"
        case .resolving: return "resolving"
        case .preparingStream: return "preparingStream"
        case .downloading: return "downloading"
        case .buffering: return "buffering"
        case .ready: return "ready"
        case .playing: return "playing"
        case .seeking: return "seeking"
        case .failed: return "failed"
        }
    }

    public var progress: Double {
        switch self {
        case .downloading(let p): return p
        case .buffering(let p): return p ?? 0
        case .playing, .ready: return 1
        default: return 0
        }
    }

    public var error: VideoPlaybackError? {
        if case .failed(let e) = self { return e }
        return nil
    }

    /// Message to show the user when failed (nil otherwise).
    public var errorMessage: String? { error?.userMessage }

    /// True while the viewer should show a blocking loading affordance (spinner / percentage) and the
    /// player (if any) is not yet usefully playing.
    public var isBusy: Bool {
        switch self {
        case .resolving, .preparingStream, .downloading, .buffering, .seeking: return true
        default: return false
        }
    }

    /// True once an AVPlayer should be on screen (it may still be buffering/seeking over the top).
    public var hasPlayer: Bool {
        switch self {
        case .ready, .playing, .buffering, .seeking: return true
        default: return false
        }
    }
}

/// Maps an `AVPlayerItem.status` raw value (0 unknown, 1 readyToPlay, 2 failed) onto the viewer
/// state. Pure so the transition is testable without spinning up AVFoundation.
public enum VideoPlayerItemStatus: Int, Sendable {
    case unknown = 0
    case readyToPlay = 1
    case failed = 2

    public func nextState(error: VideoPlaybackError?) -> VideoViewerState? {
        switch self {
        case .unknown: return nil  // keep current state
        case .readyToPlay: return .ready
        case .failed: return .failed(error ?? .playerItemFailed(detail: nil))
        }
    }
}

/// Builds the `[VideoViewer]` diagnostic line.
public func videoViewerLogFields(
    filename: String? = nil,
    mime: String? = nil,
    detectedKind: MediaKind? = nil,
    state: VideoViewerState,
    strategy: String? = nil,
    localURLExists: Bool,
    assetPlayable: Bool,
    playerItemStatus: Int,
    error: String?
) -> [String: String] {
    var fields: [String: String] = [
        "state": state.label,
        "progress": String(format: "%.2f", state.progress),
        "localURLExists": "\(localURLExists)",
        "assetPlayable": "\(assetPlayable)",
        "playerItemStatus": "\(playerItemStatus)",
        "error": error ?? state.error?.token ?? "none",
    ]
    if let filename { fields["filename"] = filename }
    if let mime { fields["mime"] = mime }
    if let detectedKind { fields["detectedKind"] = detectedKind.rawValue }
    if let strategy { fields["strategy"] = strategy }
    return fields
}
