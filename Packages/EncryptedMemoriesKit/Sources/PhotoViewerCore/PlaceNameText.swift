import Foundation

/// One rule for every place name that the viewer and the map show: a name of whitespace alone is no name.
public enum PlaceNameText {
    /// `name` exactly as given when it contains a character other than whitespace or a newline, otherwise nil.
    public static func displayable(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}
