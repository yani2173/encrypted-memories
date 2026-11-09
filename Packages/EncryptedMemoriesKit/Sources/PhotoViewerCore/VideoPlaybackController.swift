import AVFoundation
import Foundation
import Observation
import PhotosCore

public struct VideoPlaybackDiagnosticEvent: Equatable, Sendable {
    public let name: String
    public let fields: [String: String]
    public let throttleSeconds: TimeInterval

    public init(name: String, fields: [String: String], throttleSeconds: TimeInterval = 0) {
        self.name = name
        self.fields = fields
        self.throttleSeconds = throttleSeconds
    }
}

public typealias VideoPlaybackDiagnosticSink = @MainActor @Sendable (VideoPlaybackDiagnosticEvent) -> Void

/// Owns the single `AVPlayer` and every AVFoundation observation for the video path, and drives the
/// `VideoViewerState` machine. Pulled out of `PhotoViewerModel` so the viewer no longer carries
/// playback wiring - the model only decides *which* source to play; this decides *how it's going*.
///
/// The one rule it enforces (the reason it exists): the UI never gets stuck. Every attached player is
/// guarded by a startup watchdog until it actually reaches `.playing`. Mid-stream stalls surface as
/// `.buffering`, and `failedToPlayToEndTime` maps to a readable error.
@MainActor
@Observable
public final class VideoPlaybackController {
    public private(set) var state: VideoViewerState = .idle
    /// The single AVPlayer (streaming or local file). `nil` for images / before a video is attached.
    public private(set) var player: AVPlayer?

    /// Retains the streaming asset + its resource-loader delegate for as long as the player lives
    /// (AVFoundation holds the resource-loader delegate weakly).
    private var streamingAsset: AnyObject?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private var watchdogGeneration: UInt64 = 0
    private var currentUID: PhotoUID?
    private var isStreaming = false
    private var hasStartedPlayback = false
    private var attachmentGeneration: UInt64 = 0
    /// The number of players that were ever attached. It only grows, so a test sees an attachment that a later
    /// teardown removed again.
    package private(set) var attachedPlayerCount = 0
    private var attachmentIdentity: VideoPlaybackAttachmentIdentity?
    private var playbackActivity: LibraryRuntimeActivityRegistration?
    private let runtimeState: LibraryRuntimeState

    /// Seconds to wait for initial playback before declaring the attempt stuck. The timer measures startup, not
    /// display readiness.
    private let startupDeadline: TimeInterval
    private let diagnostics: VideoPlaybackDiagnosticSink?

    public init(
        firstFrameDeadline: TimeInterval = 30,
        runtimeState: LibraryRuntimeState = .shared,
        diagnostics: VideoPlaybackDiagnosticSink? = nil
    ) {
        startupDeadline = firstFrameDeadline
        self.runtimeState = runtimeState
        self.diagnostics = diagnostics
    }

    // MARK: - State the model pushes in (resolution phase, before a player exists)

    public func setResolving() { transition(.resolving) }

    /// Resets to idle and tears down any player - used when navigating to a new item or when a
    /// stream-resolve turns out to be an image.
    public func reset() {
        teardown()
        transition(.idle)
    }

    // MARK: - Playback entry points

    /// Plays a range-streamed asset. Starts in `.buffering` and remains under the startup watchdog until
    /// `AVPlayer.timeControlStatus` proves that playback actually started.
    public func playStreaming(asset: AVURLAsset, retaining: AnyObject, uid: PhotoUID) {
        teardown()
        playbackActivity = runtimeState.beginActivity(.videoPlayback)
        currentUID = uid
        isStreaming = true
        streamingAsset = retaining
        transition(.preparingStream)
        attach(AVPlayerItem(asset: asset), uid: uid, initial: .buffering(nil))
    }

    /// Hard failure (resolution/download path gave up). Shows the error; no player.
    public func fail(_ error: VideoPlaybackError, uid: PhotoUID) {
        guard uid == currentUID || currentUID == nil else { return }
        teardownKeepingState()
        transition(.failed(error))
    }

    // MARK: - Attach + observe

    private func attach(_ item: AVPlayerItem, uid: PhotoUID, initial: VideoViewerState) {
        hasStartedPlayback = false
        attachedPlayerCount += 1
        let player = AVPlayer(playerItem: item)
        VideoPlaybackTuning.configure(player: player, item: item, isStreaming: isStreaming)
        attachmentGeneration &+= 1
        let identity = VideoPlaybackAttachmentIdentity(
            generation: attachmentGeneration,
            player: player,
            item: item
        )
        attachmentIdentity = identity
        self.player = player
        transition(initial)
        logPlayer(item: item, player: player)

        let box = Weak(self)

        observations.append(
            item.observe(\.status, options: [.new, .initial]) { observed, _ in
                let raw = observed.status.rawValue
                let error = observed.error
                Task { @MainActor in
                    box.value?.onStatus(raw, error: error, uid: uid, identity: identity)
                }
            })
        observations.append(
            item.observe(\.duration, options: [.new, .initial]) { observed, _ in
                Task { @MainActor in
                    box.value?.onDurationKnown(of: observed, uid: uid, identity: identity)
                }
            })
        observations.append(
            player.observe(\.timeControlStatus, options: [.new]) { observed, _ in
                let raw = observed.timeControlStatus.rawValue
                Task { @MainActor in
                    box.value?.onTimeControl(raw, uid: uid, identity: identity)
                }
            })

        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                Task { @MainActor in
                    box.value?.onFailedToPlayToEnd(error, uid: uid, identity: identity)
                }
            })
        notificationTokens.append(
            center.addObserver(
                forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
            ) { _ in
                Task { @MainActor in
                    box.value?.onStalled(uid: uid, identity: identity)
                }
            })
        notificationTokens.append(
            center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { _ in
                Task { @MainActor in
                    box.value?.onEnded(uid: uid, identity: identity)
                }
            })

        startWatchdogIfNeeded(uid: uid, identity: identity)
        player.play()
    }

    // MARK: - Observation handlers

    private func onDurationKnown(
        of item: AVPlayerItem,
        uid: PhotoUID,
        identity: VideoPlaybackAttachmentIdentity
    ) {
        guard isCurrent(uid: uid, identity: identity), isStreaming else { return }
        VideoPlaybackTuning.reportDuration(of: item, to: streamingAsset as? StreamingVideoAsset)
    }

    private func onStatus(
        _ raw: Int,
        error: Error?,
        uid: PhotoUID,
        identity: VideoPlaybackAttachmentIdentity
    ) {
        guard isCurrent(uid: uid, identity: identity), let player else { return }
        logPlayer(item: player.currentItem, player: player, error: error)
        guard
            let next = VideoPlayerItemStatus(rawValue: raw)?
                .nextState(error: error.map(VideoPlaybackError.classify))
        else { return }
        switch next {
        case .ready:
            if player.timeControlStatus != .playing { transition(.ready) }
        case .failed(let playbackError):
            handleFailure(playbackError, uid: uid, identity: identity)
        default:
            break
        }
    }

    /// `timeControlStatus` is authoritative for native play, pause, replay, and waiting. This handler only
    /// mirrors the native state. It never issues play or pause commands.
    private func onTimeControl(
        _: Int,
        uid: PhotoUID,
        identity: VideoPlaybackAttachmentIdentity
    ) {
        guard isCurrent(uid: uid, identity: identity), let player else { return }
        logPlayer(item: player.currentItem, player: player)
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            transition(.buffering(nil))
            startWatchdogIfNeeded(uid: uid, identity: identity)
        case .playing:
            hasStartedPlayback = true
            cancelWatchdog()
            transition(.playing)
        case .paused:
            cancelWatchdog()
            if state.isBusy { transition(.ready) }
        @unknown default:
            break
        }
    }

    private func onFailedToPlayToEnd(
        _ error: NSError?,
        uid: PhotoUID,
        identity: VideoPlaybackAttachmentIdentity
    ) {
        guard isCurrent(uid: uid, identity: identity) else { return }
        handleFailure(
            error.map(VideoPlaybackError.classify) ?? .playerItemFailed(detail: "failedToPlayToEnd"),
            uid: uid,
            identity: identity
        )
    }

    private func onStalled(uid: PhotoUID, identity: VideoPlaybackAttachmentIdentity) {
        guard isCurrent(uid: uid, identity: identity), let player else { return }
        logPlayer(item: player.currentItem, player: player)
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            transition(.buffering(nil))
        }
    }

    private func onEnded(uid: PhotoUID, identity: VideoPlaybackAttachmentIdentity) {
        guard isCurrent(uid: uid, identity: identity) else { return }
        cancelWatchdog()
        transition(.ready)
    }

    private func isCurrent(uid: PhotoUID, identity: VideoPlaybackAttachmentIdentity) -> Bool {
        guard uid == currentUID,
            identity.generation == attachmentGeneration,
            attachmentIdentity == identity,
            let player,
            let item = player.currentItem
        else { return false }
        return identity.matches(generation: identity.generation, player: player, item: item)
    }

    /// A player-level failure is surfaced directly. We deliberately do not fall back to a full local video
    /// download: that would require a decrypted plaintext temp file, violating the app-wide local E2EE rule.
    private func handleFailure(
        _ error: VideoPlaybackError,
        uid: PhotoUID,
        identity: VideoPlaybackAttachmentIdentity
    ) {
        guard isCurrent(uid: uid, identity: identity) else { return }
        teardownKeepingState()
        transition(.failed(error))
    }

    // MARK: - Watchdog

    private func startWatchdogIfNeeded(uid: PhotoUID, identity: VideoPlaybackAttachmentIdentity) {
        guard watchdog == nil, !hasStartedPlayback else { return }
        let deadline = startupDeadline
        watchdogGeneration &+= 1
        let generation = watchdogGeneration
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard let self, !Task.isCancelled else { return }
            guard self.watchdogGeneration == generation else { return }
            self.watchdog = nil
            guard self.isCurrent(uid: uid, identity: identity), !self.hasStartedPlayback,
                self.player?.timeControlStatus != .paused
            else { return }
            self.emitDiagnostics([
                "event": "watchdogTimeout", "deadline": "\(Int(deadline))s",
            ])
            self.handleFailure(.timedOut, uid: uid, identity: identity)
        }
    }

    private func cancelWatchdog() {
        watchdogGeneration &+= 1
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - Teardown

    /// Full teardown: stops the player, removes observers, clears state owner.
    public func teardown() {
        attachmentGeneration &+= 1
        attachmentIdentity = nil
        cancelWatchdog()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        (streamingAsset as? StreamingVideoAsset)?.close()
        streamingAsset = nil
        playbackActivity?.end()
        playbackActivity = nil
        currentUID = nil
        hasStartedPlayback = false
        isStreaming = false
    }

    /// Tears down the player/observers but keeps `currentUID` so a `.failed` state stays attributed to
    /// the right item (used right before transitioning to `.failed`).
    private func teardownKeepingState() {
        let uid = currentUID
        teardown()
        currentUID = uid
    }

    // MARK: - State + logging

    private func transition(_ next: VideoViewerState) {
        guard state != next else { return }
        state = next
    }

    private func emitDiagnostics(_ fields: [String: String], throttleSeconds: TimeInterval = 0) {
        diagnostics?(
            VideoPlaybackDiagnosticEvent(
                name: "VideoPlayer",
                fields: fields,
                throttleSeconds: throttleSeconds
            ))
    }

    private func logPlayer(item: AVPlayerItem?, player: AVPlayer, error: Error? = nil) {
        guard let item else { return }
        let loaded = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .map {
                "\(String(format: "%.1f", $0.start.seconds))-\(String(format: "%.1f", ($0.start + $0.duration).seconds))"
            }
            .joined(separator: ",")
        let duration = item.duration.isNumeric ? String(format: "%.1f", item.duration.seconds) : "?"
        emitDiagnostics(
            [
                "status": "\(item.status.rawValue)",
                "timeControl": "\(player.timeControlStatus.rawValue)",
                "bufferEmpty": "\(item.isPlaybackBufferEmpty)",
                "likelyToKeepUp": "\(item.isPlaybackLikelyToKeepUp)",
                "loadedTimeRanges": loaded.isEmpty ? "none" : loaded,
                "duration": duration,
                "state": state.label,
                "error": (error.map(VideoPlaybackError.classify)?.token) ?? state.error?.token ?? "none",
            ], throttleSeconds: 0.3)
    }
}

/// Sendable weak box so the `@Sendable` KVO / notification / progress closures can hop back to a
/// `@MainActor` owner (this controller, the viewer model) without capturing it directly under Swift 6
/// concurrency. All access happens inside a `@MainActor` Task.
package final class Weak<T: AnyObject>: @unchecked Sendable {
    package weak var value: T?
    package init(_ value: T) { self.value = value }
}
