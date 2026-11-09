import Foundation

/// Prepares a video and asks again behind the loading indicator while the failure goes away by itself, for example a
/// rate limit. The waits come from `VideoPlaybackError.silentRetryDelays`. A cancelled task ends the loop at once, so
/// a host that cancels the preparation when the person moves on never asks again.
public enum VideoPreparationRetry {
    /// Returns the result of the first attempt that succeeds. Throws the failure of the last attempt when its class
    /// has no wait left, and a `CancellationError` when the task is cancelled during a wait.
    public static func run<Result>(
        delays: (VideoPlaybackError) -> [Duration] = { $0.silentRetryDelays },
        wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        attempt: () async throws -> Result
    ) async throws -> Result {
        var retries = 0
        while true {
            do {
                return try await attempt()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled,
                    let delay = delays(VideoPlaybackError.classify(error)).dropFirst(retries).first
                else { throw error }
                await wait(delay)
                try Task.checkCancellation()
                retries += 1
            }
        }
    }
}
