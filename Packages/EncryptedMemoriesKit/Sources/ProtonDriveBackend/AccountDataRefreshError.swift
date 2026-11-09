import Foundation

/// A refresh failure does not prove that Proton rejected the saved session.
enum AccountDataRefreshError: LocalizedError {
    case unavailable

    /// The library-open view already supplies the error title and Retry action.
    /// An unclear cause adds no technical detail or unproved reason.
    var errorDescription: String? { "" }
}

enum TokenRefreshOutcome: Sendable {
    case refreshed
    case rejected
    case unavailable
}
