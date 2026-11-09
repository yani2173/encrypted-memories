import Foundation

/// The reason and available action of a failed "Keep Only Favorites" attempt.
public struct SeriesFailurePresentation: Equatable, Sendable {
    public let message: String
    public let canRetry: Bool

    public init(error: any Error) {
        if let failure = error as? SeriesDissolutionError {
            message = failure.errorDescription ?? ""
            // An invalid selection is the person's doing, and a missing library service needs more than a new
            // attempt, so neither offers a retry. Every other reason can resolve on a new attempt.
            canRetry = failure != .invalidSelection && failure != .libraryUnavailable
        } else {
            message = ""
            canRetry = true
        }
    }
}
