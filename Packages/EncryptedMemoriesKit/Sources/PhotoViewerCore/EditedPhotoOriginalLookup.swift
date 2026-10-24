import Foundation
import PhotosCore

/// What the viewer knows about the originals of edited photos, and which version it shows. Platform-neutral.
public struct EditedPhotoOriginalState: Equatable, Sendable {
    private var originals: [PhotoUID: PhotoItem] = [:]
    private var showingOriginalOf: PhotoUID?

    public init() {}

    public func canShowOriginal(of base: PhotoUID) -> Bool { originals[base] != nil }

    public func isShowingOriginal(of base: PhotoUID) -> Bool {
        showingOriginalOf == base && originals[base] != nil
    }

    /// The item the viewer displays for the page of `base`.
    public func displayed(_ base: PhotoItem) -> PhotoItem {
        guard isShowingOriginal(of: base.uid), let original = originals[base.uid] else { return base }
        return original
    }

    /// A found original stays for the viewer's lifetime, so the control appears at most once and never goes away.
    public mutating func record(_ original: PhotoItem, of base: PhotoUID) {
        if originals[base] == nil { originals[base] = original }
    }

    /// Switches the page of `base` between the edited version and the original.
    public mutating func toggle(_ base: PhotoUID) {
        guard originals[base] != nil else { return }
        showingOriginalOf = showingOriginalOf == base ? nil : base
    }

    /// Another page shows its edited version again.
    public mutating func pageChanged(to base: PhotoUID?) {
        if showingOriginalOf != base { showingOriginalOf = nil }
    }
}

/// Asks the backend for the original of the settled page, sparingly.
///
/// A photo must stay the settled page for `dwell` before the ask starts, so paging through photos sends nothing. The
/// ask is cancelled when the person pages on. Each photo that got an answer, with or without an original, is asked at
/// most once per viewer; the backend keeps the answer for the session. A skipped or failed ask is not an answer:
/// - Without a provider the photo waits for `providerAvailable(_:)`.
/// - After the dwell the ask waits until the app admits it: foreground active on an unconstrained network.
/// - A fetch that threw leaves the photo unanswered, so the next `settled` for it asks again.
/// Only the photo on screen waits: the next `settled` or `cancel()` drops every waiting ask.
@MainActor
public final class EditedPhotoOriginalLookup {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    /// A stream that yields whenever the conditions behind `admits` may have changed.
    public typealias Changes = @Sendable () -> AsyncStream<Void>

    public static let dwell: Duration = .seconds(1)

    private let sleep: Sleep
    private let admits: @Sendable () -> Bool
    private let changes: Changes
    private var answered: Set<PhotoUID> = []
    private var waitingForProvider: (item: PhotoItem, found: @MainActor (PhotoItem, PhotoItem) -> Void)?
    private(set) var pending: Task<Void, Never>?

    public init(
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        admits: @escaping @Sendable () -> Bool = {
            EditedPhotoOriginalLookup.admits(LibraryRuntimeState.shared.snapshot())
        },
        changes: @escaping Changes = { EditedPhotoOriginalLookup.runtimeChanges() }
    ) {
        self.sleep = sleep
        self.admits = admits
        self.changes = changes
    }

    /// The ask is a low-priority extra: only while the app is active in the foreground on an unconstrained network.
    public nonisolated static func admits(_ snapshot: LibraryRuntimeSnapshot) -> Bool {
        snapshot.executionOpportunity == .foregroundActive && snapshot.network.isReachable
            && !snapshot.network.isConstrained
    }

    /// Yields on every change of the shared runtime state, and once at the start.
    public nonisolated static func runtimeChanges() -> AsyncStream<Void> {
        let updates = LibraryRuntimeState.shared.updates()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let forwarding = Task {
                for await _ in updates { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }

    /// Call whenever the settled page changes. `found` receives the page's item and its original. Without a provider,
    /// for example while the library still loads, the photo waits for `providerAvailable(_:)`.
    public func settled(
        on item: PhotoItem?, provider: (any EditedPhotoOriginalProviding)?,
        found: @escaping @MainActor (PhotoItem, PhotoItem) -> Void
    ) {
        cancel()
        guard let item, item.mayHaveEditedOriginal, !answered.contains(item.uid) else { return }
        guard let provider else {
            waitingForProvider = (item, found)
            return
        }
        pending = Task { [sleep, admits, changes] in
            do { try await sleep(Self.dwell) } catch { return }
            guard await Self.waitUntilAdmitted(admits, changes) else { return }
            // The wait can end true, and the page can change or an earlier ask for this photo can finish, before this
            // continuation runs. Nothing suspends between this check and the call.
            guard !Task.isCancelled, !self.answered.contains(item.uid) else { return }
            let original: PhotoItem?
            do { original = try await provider.editedOriginal(of: item) } catch { return }
            // An answer stays an answer when the person paged on during the call: the original is recorded by photo,
            // so it shows when the photo returns, and the photo is not asked again.
            self.answered.insert(item.uid)
            if let original { found(item, original) }
        }
    }

    /// The provider became available. A photo that waited for it starts its ask now, with a new dwell.
    public func providerAvailable(_ provider: any EditedPhotoOriginalProviding) {
        guard let waiting = waitingForProvider else { return }
        settled(on: waiting.item, provider: provider, found: waiting.found)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
        waitingForProvider = nil
    }

    /// Returns true as soon as `admits` is true. Returns false when the task is cancelled first, or when the stream of
    /// changes finishes before `admits` is true; the default runtime stream has no ordinary finish.
    private nonisolated static func waitUntilAdmitted(
        _ admits: @Sendable () -> Bool, _ changes: Changes
    ) async -> Bool {
        if admits() { return !Task.isCancelled }
        var iterator = changes().makeAsyncIterator()
        while !Task.isCancelled {
            if admits() { return true }
            guard await iterator.next() != nil else { return false }
        }
        return false
    }
}
