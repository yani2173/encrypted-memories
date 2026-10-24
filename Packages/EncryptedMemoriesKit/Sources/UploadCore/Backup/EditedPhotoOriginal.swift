import Foundation

/// Finds the unedited original among the hidden related files of an edited photo or video from the photo library
/// backup. The backup uploads the rendered edit as the photo and every other resource, the original too, as a related
/// file. A related file carries no role, so only its name tells the original apart.
///
/// The backup names the photo after the original with the extension of the render: `IMG_1.HEIC` with
/// `FullSizeRender.jpg` uploads as `IMG_1.jpg` next to the related `IMG_1.HEIC`. When both names differ only in
/// case, the original becomes `IMG_1-originalPhoto-1.heic` (`-originalVideo-` for a video).
///
/// The caller passes only plain photos and videos, no Live Photo and no series: their original is more than one file.
public enum EditedPhotoOriginal {
    public struct RelatedFile: Sendable, Equatable {
        public var linkID: String
        /// Nil when the name does not decrypt.
        public var name: String?

        public init(linkID: String, name: String?) {
            self.linkID = linkID
            self.name = name
        }
    }

    /// The link of the original, or nil when the related files do not prove exactly one.
    ///
    /// - Adjustment data (`.plist` or `.AAE`) must prove the edit; without it, an image with the same base name is a
    ///   RAW file or another resource of an unedited photo.
    /// - A name that the backup marked with the original's role decides first.
    /// - Otherwise exactly one image (video, for a video) must share the photo's base name. A DNG never counts: the
    ///   RAW file of a RAW+JPEG pair whose edit uploaded without a render looks like the original of a ProRAW edit.
    /// - A name that does not decrypt can be the original, so it leaves the answer open.
    public static func linkID(mainName: String, isVideo: Bool, related: [RelatedFile]) -> String? {
        var names: [(linkID: String, name: String)] = []
        for file in related {
            guard let name = file.name else { return nil }
            names.append((file.linkID, name))
        }
        guard names.contains(where: { adjustmentExtensions.contains(fileExtension($0.name)) }) else { return nil }

        let kind: SupportedMedia.Kind = isVideo ? .video : .image
        let base = baseName(mainName).lowercased()
        let media = names.filter { SupportedMedia.kind(for: URL(fileURLWithPath: $0.name)) == kind }

        let roleMarker = "\(base)-\(isVideo ? "originalVideo" : "originalPhoto")-".lowercased()
        let marked = media.filter { file in
            let candidate = baseName(file.name).lowercased()
            guard candidate.hasPrefix(roleMarker) else { return false }
            let suffix = candidate.dropFirst(roleMarker.count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isASCIIDigit)
        }
        if !marked.isEmpty { return marked.count == 1 ? marked[0].linkID : nil }

        let sameBase = media.filter { file in
            baseName(file.name).lowercased() == base && fileExtension(file.name) != "dng"
        }
        return sameBase.count == 1 ? sameBase[0].linkID : nil
    }

    static let adjustmentExtensions: Set<String> = ["plist", "aae"]

    private static func baseName(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
