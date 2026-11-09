import Foundation

/// The name of the photo that a revert to original restores: "`<base> (original).<ext>`". The base is the edited
/// photo's name without its extension. The extension is the original's, because the restored bytes are the
/// original's. The hidden original itself is named differently (for example `IMG_0001-originalPhoto-1.heic`), so
/// the restored photo never shares its name.
public enum EditedOriginalRestoredName {
    /// The one place of the pattern: the text between the base and the extension.
    public static let marker = " (original)"

    /// Nil when no valid name exists: an input name holds a path separator or NUL, or the edited photo's base is empty.
    /// The inputs are checked as given, because the extension logic drops a trailing separator from them.
    public static func make(mainName: String, originalName: String) -> String? {
        for name in [mainName, originalName] where name.contains("/") || name.contains("\0") { return nil }
        let base = (mainName as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        let pathExtension = (originalName as NSString).pathExtension
        return pathExtension.isEmpty ? base + marker : base + marker + "." + pathExtension
    }
}
