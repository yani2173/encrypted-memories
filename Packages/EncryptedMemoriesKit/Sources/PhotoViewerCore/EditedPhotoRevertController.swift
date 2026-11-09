import Observation
import PhotosCore

/// The confirmation, the run and the failure of "Revert to Original" in a viewer. Platform-neutral: the viewers
/// of macOS, iOS and iPadOS share this type and only draw its phases.
@MainActor
@Observable
public final class EditedPhotoRevertController {
    public enum Phase: Equatable, Sendable {
        /// Nothing is asked and nothing runs.
        case idle
        /// The confirmation alert shows. Nothing was written yet.
        case confirming
        /// The revert runs. A repeated tap starts nothing.
        case running
        /// The failure alert shows once. There is no retry.
        case failed
    }

    public private(set) var phase: Phase = .idle
    @ObservationIgnored package private(set) var current: Task<Void, Never>?
    /// The viewer's reaction to a finished revert. It is dropped by `detach` and after it ran.
    @ObservationIgnored private var onSuccess: (@MainActor () -> Void)?

    public init() {}

    public var isConfirming: Bool { phase == .confirming }
    public var showsFailure: Bool { phase == .failed }

    /// The command shows only for a photo with a proven original, in the own library, with a backend that reverts.
    /// The own library is the context where the viewer's mutation is "Move to Trash": the Trash and a shared album
    /// have other mutations and never offer the revert.
    public nonisolated static func isAvailable(
        canShowOriginal: Bool, mutationAction: ViewerMutationAction?, hasReverter: Bool
    ) -> Bool {
        canShowOriginal && mutationAction == .moveToTrash && hasReverter
    }

    /// True when the command may start a revert now: it is available, and no confirmation, run or failure is open.
    public func canStart(canShowOriginal: Bool, mutationAction: ViewerMutationAction?, hasReverter: Bool) -> Bool {
        phase == .idle
            && Self.isAvailable(
                canShowOriginal: canShowOriginal, mutationAction: mutationAction, hasReverter: hasReverter)
    }

    /// Opens the confirmation. Nothing is written until `confirm`.
    public func request() {
        guard phase == .idle else { return }
        phase = .confirming
    }

    /// The person chose Cancel: nothing changes.
    public func cancel() {
        guard phase == .confirming else { return }
        phase = .idle
    }

    /// The viewer moved to another page. A pending confirmation ends; a running revert goes on, because its journal
    /// keeps it safe and the result belongs to the photo that the person confirmed.
    public func pageChanged() { cancel() }

    /// The person closed the failure alert. The failure does not come back, and nothing offers a retry.
    public func dismissFailure() {
        guard phase == .failed else { return }
        phase = .idle
    }

    /// `confirm` for the revert of one photo: it calls the reverter, then `onReverted` (host work that must happen
    /// whatever the viewer does, for example the removal of the edited photo from the timeline), and only then
    /// `onSuccess`. A failed revert runs neither.
    public func confirm(
        main: PhotoItem, original: PhotoItem, reverter: any EditedPhotoReverting,
        onReverted: (@MainActor @Sendable (PhotoItem) async -> Void)? = nil,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        confirm(
            perform: {
                try await reverter.revertToOriginal(of: main, original: original)
                await onReverted?(main)
            },
            onSuccess: onSuccess)
    }

    /// Starts the revert once. Only the first call after `request` starts it: a repeated tap meets `running` and does
    /// nothing. `onSuccess` runs only while the controller still exists, so a revert that ends after the viewer closed
    /// never acts on another photo that the person opened meanwhile. Work that must happen in every case belongs into
    /// `perform`.
    public func confirm(
        perform: @escaping @MainActor @Sendable () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard phase == .confirming else { return }
        phase = .running
        self.onSuccess = onSuccess
        current = Task { [weak self] in
            do {
                try await perform()
                guard let self else { return }
                phase = .idle
                // The callback leaves the controller before it runs, so it runs at most once.
                let callback = self.onSuccess
                self.onSuccess = nil
                callback?()
            } catch is CancellationError {
                // The account or the app ended the work: nothing failed that the person could act on.
                self?.onSuccess = nil
                self?.phase = .idle
            } catch {
                self?.onSuccess = nil
                self?.phase = .failed
            }
        }
    }

    /// The viewer closed. The success callback is dropped, so a revert that ends later closes nothing; a pending
    /// confirmation ends. The revert itself goes on, and the work that it must do in every case belongs into `perform`.
    /// A weak reference cannot do this: the callback captures the viewer, the viewer keeps its model, and the model
    /// keeps this controller, so the controller outlives the viewer until the revert ends.
    public func detach() {
        onSuccess = nil
        cancel()
    }
}
