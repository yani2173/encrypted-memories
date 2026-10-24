import Foundation
import PhotosCore

/// Shared first-load presentation state.
///
/// `contentReady` follows the first visible thumbnails; `empty`
/// and `failed` are terminal. Progress remains indeterminate because inventory count is not a measured fraction.
public enum LibraryLoadState: Equatable, Sendable {
    /// The backend is preparing the inventory and has no count yet.
    case preparingInventory

    /// The inventory count is known, but visible thumbnails are not ready.
    case loadingContent(count: Int, usingCachedInventory: Bool)

    /// A persisted empty inventory is awaiting server validation.
    case validatingCachedContent(count: Int)

    /// The first visible thumbnails are drawn and the grid is presentable.
    case contentReady(count: Int)

    /// The library finished loading and contains no photos.
    case empty

    /// Loading failed before any content could be presented. `retryable` requests a retry affordance.
    case failed(message: String, retryable: Bool)

    /// The initial state entered on sign-in (and on every reset).
    public static let initial: LibraryLoadState = .preparingInventory
}

public extension LibraryLoadState {
    /// The known photo count once the inventory has resolved (cached or fresh); `nil` while still preparing or
    /// after a failure. `empty` reports `0` so the shell can render "0 photos" calmly.
    var knownCount: Int? {
        switch self {
        case .loadingContent(let count, _): return count
        case .validatingCachedContent(let count): return count
        case .contentReady(let count): return count
        case .empty: return 0
        case .preparingInventory, .failed: return nil
        }
    }

    /// True while the shell must show the onboarding/loading UI (spinner + factual status), not the grid.
    var isLoading: Bool {
        switch self {
        case .preparingInventory, .loadingContent, .validatingCachedContent: return true
        case .contentReady, .empty, .failed: return false
        }
    }

    /// True once the grid is safe to present (first thumbnails drawn). The shell shows the timeline here.
    var isContentReady: Bool {
        if case .contentReady = self { return true }
        return false
    }

    /// True once loading settled on a truly empty library - the only case where a blank grid is acceptable.
    var isEmpty: Bool { isCompletelyEmpty }

    /// Completely empty means a successful, complete authoritative listing has zero known items,
    /// or this app initialized the account library empty. Only those outcomes may publish `.empty`.
    /// An unknown first page, a partial listing, cancellation, failure and an unvalidated empty cache
    /// provide no such proof. This rule uses known metadata, never an estimated total.
    var isCompletelyEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    /// The failure details, if the load failed before any content was presented.
    var failure: (message: String, retryable: Bool)? {
        if case .failed(let message, let retryable) = self { return (message, retryable) }
        return nil
    }

    /// Returns whether loading has reached a presentable terminal state.
    var hasSettled: Bool {
        switch self {
        case .contentReady, .empty, .failed: return true
        case .preparingInventory, .loadingContent, .validatingCachedContent: return false
        }
    }
}

/// Events that drive `LibraryLoadState`. All inputs are plain scalars so the reducer stays a pure, trivially
/// testable value transform with no dependency on the feed/backend/crawl machinery.
public enum LibraryLoadEvent: Equatable, Sendable {
    /// The inventory count became known - from either a cached snapshot (`cached: true`) or a fresh server load
    /// (`cached: false`). A fresh count requires a successful complete listing, or app-owned empty initialization.
    case inventoryResolved(count: Int, cached: Bool)

    /// The initial server refresh completed. `requiresNewFrame` is true only when the ordered photo identities
    /// changed, which makes the currently rendered cached frame obsolete.
    case authoritativeInventoryResolved(count: Int, requiresNewFrame: Bool)

    /// The grid reported that the first visible thumbnails are drawn.
    case firstContentReady

    /// Loading failed. `retryable` requests a retry affordance in the shell.
    case failed(message: String, retryable: Bool)

    /// Inventory exists, but its byte route cannot produce the first visible frame.
    case contentLoadFailed(message: String)

    /// A new session / sign-out / manual retry restarts the lifecycle at `preparingInventory`.
    case reset
}

/// The pure reducer. Kept separate from the state so the whole policy is one referentially-transparent function
/// that macOS and iOS share verbatim.
public enum LibraryLoadPolicy {
    public static func reduce(_ state: LibraryLoadState, _ event: LibraryLoadEvent) -> LibraryLoadState {
        switch event {
        case .contentLoadFailed(let message):
            switch state {
            case .contentReady, .empty: return state
            default: return .failed(message: message, retryable: true)
            }
        case .reset:
            return .preparingInventory

        case .failed(let message, let retryable):
            // A failure only surfaces when there is nothing presentable yet (still preparing, or a prior
            // failure). Once an inventory has resolved - even a stale cached one still drawing, or a settled
            // empty/ready grid - a later (background refresh) failure must not replace it: the user keeps their
            // photos and browses offline instead of hitting an error wall.
            switch state {
            case .preparingInventory, .failed:
                return .failed(message: message, retryable: retryable)
            case .loadingContent(let count, let usingCachedInventory) where usingCachedInventory:
                // The server validation failed, but a cached inventory is already mounting. Accept that
                // inventory for offline presentation and keep waiting for the real viewport-ready event. This
                // is order-independent with the validatingCachedContent branch below.
                return .loadingContent(count: count, usingCachedInventory: false)
            case .loadingContent, .contentReady, .empty:
                return state
            case .validatingCachedContent(let count):
                return count == 0
                    ? .failed(message: message, retryable: retryable)
                    : .contentReady(count: count)
            }

        case .inventoryResolved(let count, let cached):
            guard count >= 0 else { return .preparingInventory }
            guard count > 0 else {
                // A persisted empty inventory is still provisional until its paired server token validates.
                // Presenting `.empty` immediately would flash an empty state before a changed server library
                // replaces it. Fresh authoritative zero is final and can settle at once.
                return cached ? .validatingCachedContent(count: 0) : .empty
            }
            // Keep presented content while updating its count.
            if case .contentReady = state { return .contentReady(count: count) }
            return .loadingContent(count: count, usingCachedInventory: cached)

        case .authoritativeInventoryResolved(let count, let requiresNewFrame):
            guard count >= 0 else { return .preparingInventory }
            guard count > 0 else { return .empty }
            if case .contentReady = state { return .contentReady(count: count) }
            if case .validatingCachedContent = state, !requiresNewFrame {
                return .contentReady(count: count)
            }
            return .loadingContent(count: count, usingCachedInventory: false)

        case .firstContentReady:
            switch state {
            case .loadingContent(let count, _):
                // A fully drawn cached viewport is already useful, truthful content. Server-token validation
                // continues in the background and only publishes a replacement when the inventory really
                // changed; it must never hold a warm launch behind network latency.
                return .contentReady(count: count)
            case .contentReady:
                return state
            case .validatingCachedContent:
                return state
            // First content cannot precede a known, non-empty inventory; ignore in every other state so a stray
            // signal can never reveal an unprepared or empty grid.
            case .preparingInventory, .empty, .failed:
                return state
            }
        }
    }
}

/// The library is completely empty only when complete, authoritative known metadata contains zero items.
/// App-owned empty initialization establishes that same authority. Cached, partial, failed, cancelled and
/// offline first reads cannot establish it. A missing first page has no known count. Totals are never estimated.
public enum LibraryEmptyPolicy {
    public static func isCompletelyEmpty(knownItemCount: Int?, authority: SourceInventoryAuthority) -> Bool {
        knownItemCount == 0 && authority == .authoritative
    }
}
