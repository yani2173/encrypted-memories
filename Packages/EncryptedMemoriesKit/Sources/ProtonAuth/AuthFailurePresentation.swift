import PhotosCore

/// Describes the failed sign-in step without exposing API or Keychain diagnostics.
enum AuthFailurePresentation {
    enum Context {
        case authentication
        case savedSessionRead
        case sessionSave
    }

    static func message(for error: any Error, context: Context) -> String {
        switch context {
        case .savedSessionRead:
            return L10n.string("auth.saved_sign_in_unreadable")
        case .sessionSave:
            return L10n.string("auth.sign_in_not_saved")
        case .authentication:
            if let authError = error as? ProtonAuthError {
                switch authError {
                case .timedOut: return L10n.string("error.auth_timed_out")
                case .cancelled: return L10n.string("error.auth_cancelled")
                default: break
                }
            }
            return L10n.string("auth.sign_in_incomplete")
        }
    }
}
