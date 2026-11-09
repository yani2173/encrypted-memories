import Foundation

/// The one builder of the library-load error screen's message. The iOS and macOS load paths both read
/// this function so the screen's text stays identical across platforms.
public enum LibraryLoadFailureMessage {
    /// Maps a first library-load failure to the text the error screen shows.
    ///
    /// A failed library creation shows one generic text that names no cause. Every other failure
    /// keeps its localized description.
    public static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
