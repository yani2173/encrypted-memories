import Foundation

extension PhotoUID {
    /// The key of a photo in the process-local `NSCache` tiers (thumbnail bytes, decoded thumbnails, viewer images).
    /// It is not security sensitive and never written to disk. `ThumbnailFeedCore` also formats it into the error text
    /// that its error log keeps and that the support export can include.
    package var cacheKey: NSString { "\(volumeID)~\(nodeID)" as NSString }
}
