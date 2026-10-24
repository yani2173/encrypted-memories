import Observation
import PhotosCore
import SwiftUI
import UIKit

/// One iOS/iPadOS selection state machine shared by the main timeline, collection grids and map results.
/// Platform screens only provide their item source and the existing backend action; Select-button mode transitions, bounded original export and honest error/partial-result state stay identical everywhere.
@MainActor
@Observable
final class MobileGridSelectionController {
    var isSelecting = false
    var selected: Set<PhotoUID> = []
    var sharePayload: MobileSharePayload?
    var partialShare: MobilePartialShare?
    var isExporting = false
    var isFavoriting = false
    var isTrashing = false
    var showTrashConfirm = false
    var actionError: MobileSelectionError?
    private var exportTask: Task<Void, Never>?

    isolated deinit { exportTask?.cancel() }

    var isBusy: Bool { isExporting || isFavoriting || isTrashing }

    func toggleMode() {
        toggleMode(reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func toggleMode(reduceMotion: Bool) {
        guard !isBusy else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            if isSelecting {
                isSelecting = false
                selected.removeAll(keepingCapacity: false)
            } else {
                isSelecting = true
            }
        }
    }

    func toggle(_ item: PhotoItem) {
        guard !isBusy else { return }
        if selected.contains(item.uid) {
            selected.remove(item.uid)
        } else {
            selected.insert(item.uid)
        }
    }

    /// Applies the complete selection reported by a grid swipe. The grid derives it from the state before the swipe.
    func replace(with uids: Set<PhotoUID>) {
        guard isSelecting, !isBusy else { return }
        selected = uids
    }

    func finish() {
        finish(reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func finish(reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            isSelecting = false
            selected.removeAll(keepingCapacity: false)
        }
    }

    func startShare(
        items: [PhotoItem],
        backend: any OriginalFileProvider & PhotoMetadataProvider,
        failureMessage: String = String(localized: "selection.share_failed")
    ) {
        guard !items.isEmpty, !isBusy else { return }
        isExporting = true
        exportTask = Task { [weak self] in
            // A Live Photo leaves as its still and its motion video.
            let files = OutboundMedia.files(for: items).map(\.item)
            let result = await MobileMediaExporter.exportOriginals(files, backend: backend)
            guard let self else {
                MobileMediaExporter.cleanup(result.urls)
                return
            }
            self.exportTask = nil
            self.isExporting = false
            guard !Task.isCancelled else {
                MobileMediaExporter.cleanup(result.urls)
                return
            }
            if result.urls.isEmpty {
                self.actionError = MobileSelectionError(
                    message: result.ranOutOfSpace ? String(localized: "selection.share_failed_space") : failureMessage)
            } else if result.failed > 0 {
                self.partialShare = MobilePartialShare(
                    urls: result.urls, failed: result.failed, ranOutOfSpace: result.ranOutOfSpace)
            } else {
                self.sharePayload = MobileSharePayload(urls: result.urls)
            }
        }
    }

    func performTrash(
        failureMessage: String = String(localized: "selection.trash_failed"),
        _ action: @escaping @MainActor (Set<PhotoUID>) async throws -> Void
    ) {
        let uids = selected
        guard !uids.isEmpty, !isBusy else { return }
        isTrashing = true
        Task {
            defer { isTrashing = false }
            do {
                try await action(uids)
                finish()
            } catch {
                actionError = MobileSelectionError(message: failureMessage)
            }
        }
    }

    func performFavorite(
        failureMessage: String = String(localized: "selection.favorite_failed"),
        _ action: @escaping @MainActor (Set<PhotoUID>) async -> Bool
    ) {
        let uids = selected
        guard !uids.isEmpty, !isBusy else { return }
        isFavoriting = true
        Task {
            defer { isFavoriting = false }
            if !(await action(uids)) {
                actionError = MobileSelectionError(message: failureMessage)
            }
        }
    }
}

/// Identifiable payload for the share sheet: the on-disk file URLs exported from the selection.
struct MobileSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let completionURL: URL?
    let fileOwnership: MobileShareFileOwnership

    init(urls: [URL], completionURL: URL? = nil, fileOwnership: MobileShareFileOwnership? = nil) {
        self.urls = urls
        self.completionURL = completionURL
        self.fileOwnership = fileOwnership ?? MobileShareFileOwnership(urls: urls)
    }
}

/// Payload copies retain their files until the last presentation owner releases them.
/// Explicit completion cleanup remains idempotent; this also covers an owner that disappears before presentation.
final class MobileShareFileOwnership {
    private let urls: [URL]
    init(urls: [URL]) { self.urls = urls }
    deinit { MobileMediaExporter.cleanup(urls) }
}

/// A localized, user-facing failure for a selection action, surfaced honestly via an alert.
struct MobileSelectionError: Identifiable {
    let id = UUID()
    let message: String
}

/// A share where some originals could not be downloaded: the successfully-exported URLs plus how many were
/// dropped, so the user is told before the partial share proceeds.
struct MobilePartialShare: Identifiable {
    let id = UUID()
    let urls: [URL]
    let failed: Int
    let ranOutOfSpace: Bool
    let fileOwnership: MobileShareFileOwnership

    init(urls: [URL], failed: Int, ranOutOfSpace: Bool = false) {
        self.urls = urls
        self.failed = failed
        self.ranOutOfSpace = ranOutOfSpace
        fileOwnership = MobileShareFileOwnership(urls: urls)
    }
}

/// Native binary confirmations shared by every mobile grid selection surface. A confirmation dialog
/// is an action menu on iPhone and can appear as an anchored popover on iPad; these are yes/no
/// decisions, so the system alert treatment is the consistent platform contract on both form factors.
@MainActor
private struct MobileSelectionAlertsModifier: ViewModifier {
    let selection: MobileGridSelectionController
    let trashTitle: String
    let trashMessage: String
    let trashConfirm: String
    let onConfirmTrash: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "selection.share_partial_title"),
                isPresented: Binding(
                    get: { selection.partialShare != nil },
                    set: { if !$0 { selection.partialShare = nil } }
                ),
                presenting: selection.partialShare
            ) { info in
                Button(String(localized: "selection.share_partial_proceed")) {
                    selection.sharePayload = MobileSharePayload(urls: info.urls, fileOwnership: info.fileOwnership)
                }
                Button(L10n.string("action.cancel"), role: .cancel) {
                    MobileMediaExporter.cleanup(info.urls)
                }
            } message: { info in
                Text(
                    info.ranOutOfSpace
                        ? String(localized: "selection.share_partial_space \(info.failed)")
                        : String(localized: "selection.share_partial_message \(info.failed)"))
            }
            .alert(
                trashTitle,
                isPresented: Binding(
                    get: { selection.showTrashConfirm },
                    set: { selection.showTrashConfirm = $0 }
                )
            ) {
                Button(trashConfirm, role: .destructive) {
                    onConfirmTrash()
                }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(trashMessage)
            }
            .alert(
                selection.actionError?.message ?? "",
                isPresented: Binding(
                    get: { selection.actionError != nil },
                    set: { if !$0 { selection.actionError = nil } }
                )
            ) {
                Button(L10n.string("action.ok"), role: .cancel) {}
            }
    }
}

extension View {
    /// Installs the selection controller's two binary confirmations and action error exactly once.
    @MainActor
    func mobileSelectionAlerts(
        selection: MobileGridSelectionController,
        trashTitle: String = String(localized: "selection.trash_title"),
        trashMessage: String = String(localized: "selection.trash_message"),
        trashConfirm: String = String(localized: "selection.trash_confirm"),
        onConfirmTrash: @escaping () -> Void
    ) -> some View {
        modifier(
            MobileSelectionAlertsModifier(
                selection: selection,
                trashTitle: trashTitle,
                trashMessage: trashMessage,
                trashConfirm: trashConfirm,
                onConfirmTrash: onConfirmTrash
            ))
    }

    /// Presents the native activity controller directly from UIKit. Wrapping that controller in a
    /// SwiftUI sheet gives SwiftUI and UIKit competing ownership of the same dismissal transition.
    @MainActor
    func mobileSharePresentation(selection: MobileGridSelectionController) -> some View {
        mobileSharePresentation(
            payload: Binding(
                get: { selection.sharePayload },
                set: { selection.sharePayload = $0 }
            ))
    }

    @MainActor
    func mobileSharePresentation(payload: Binding<MobileSharePayload?>) -> some View {
        background {
            MobileActivityPresenter(payload: payload)
        }
    }
}

/// Exports selected media originals to temporary files for a native share sheet.
///
/// It shares real files, never thumbnails. The backend streams each decrypted original straight to its share
/// file; no selected photo/video is materialized as `Data`. Items whose download fails are skipped (the share
/// proceeds with whatever succeeded); if none succeed the caller surfaces the failure honestly.
enum MobileMediaExporter {
    private static var exporter: TemporaryOriginalExporter { TemporaryOriginalExporter() }

    private static func makeExportDirectory() -> URL { exporter.makeExportDirectory() }

    /// Native share completion remains responsible for releasing the job's files.
    static func cleanup(_ urls: [URL]) { exporter.cleanup(urls) }

    /// Support reports receive the same per-job ownership as original-media exports.
    static func exportSupportReport(_ data: Data) async -> URL? {
        let directory = makeExportDirectory()
        let worker = Task.detached(priority: .utility) { () -> URL? in
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Encrypted-Memories-Support.json")
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                try Task.checkCancellation()
                return url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        if Task.isCancelled {
            if let result { cleanup([result]) }
            return nil
        }
        return result
    }

    typealias ExportResult = TemporaryOriginalExporter.ExportResult

    static func exportOriginals(
        _ items: [PhotoItem],
        backend: any OriginalFileProvider & PhotoMetadataProvider,
        runtimeState: LibraryRuntimeState = .shared,
        availableCapacity: (URL) -> Int64? = DeviceStorage.availableCapacity(at:)
    ) async -> ExportResult {
        await exporter.exportOriginals(
            items, backend: backend, runtimeState: runtimeState, availableCapacity: availableCapacity)
    }
}

/// A stable UIKit presentation host for the native activity controller.
///
/// `UIActivityViewController` dismisses itself after cancellation or completion. Presenting it as
/// the content of SwiftUI's `.sheet` gives `UIKitPopoverBridge` a second dismissal owner. iOS 26.6
/// traps when both transitions run together. This host stays in the SwiftUI hierarchy and lets
/// UIKit own the activity controller's complete presentation lifecycle.
struct MobileActivityPresenter: UIViewControllerRepresentable {
    @Binding var payload: MobileSharePayload?

    @MainActor
    final class HostController: UIViewController {
        var onAppearance: (() -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppearance?()
        }
    }

    @MainActor
    final class Coordinator {
        private var pendingPayload: MobileSharePayload?
        private var activePayload: MobileSharePayload?
        private var payloadBinding: Binding<MobileSharePayload?>?
        private weak var activeController: UIActivityViewController?

        func update(
            payload: MobileSharePayload?,
            binding: Binding<MobileSharePayload?>,
            presenter: HostController
        ) {
            payloadBinding = binding
            pendingPayload = payload?.id == activePayload?.id ? nil : payload
            presentIfPossible(from: presenter)
        }

        func hostDidAppear(_ presenter: HostController) {
            presentIfPossible(from: presenter)
        }

        func prepareController(
            for payload: MobileSharePayload,
            binding: Binding<MobileSharePayload?>,
            presenter: UIViewController
        ) -> UIActivityViewController {
            begin(payload: payload, binding: binding)

            let controller = UIActivityViewController(
                activityItems: payload.urls,
                applicationActivities: nil
            )
            activeController = controller
            controller.completionWithItemsHandler = completionHandler(for: payload.id)

            if let popover = controller.popoverPresentationController {
                let bounds = presenter.view.bounds
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: bounds.midX,
                    y: bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            return controller
        }

        /// Internal seams let the iOS test invoke the completion path without starting the
        /// system share service, which continues asynchronous item inspection after initialization.
        func begin(
            payload: MobileSharePayload,
            binding: Binding<MobileSharePayload?>
        ) {
            payloadBinding = binding
            activePayload = payload
        }

        func completionHandler(
            for payloadID: UUID
        ) -> UIActivityViewController.CompletionWithItemsHandler {
            { [weak self] _, _, _, _ in
                self?.complete(payloadID: payloadID)
            }
        }

        func dismantle(presenter: HostController) {
            let retainedPayloads = [activePayload, pendingPayload].compactMap { $0 }
            let urls = (activePayload?.urls ?? []) + (pendingPayload?.urls ?? [])
            pendingPayload = nil
            activePayload = nil
            payloadBinding = nil

            guard let controller = activeController else {
                MobileMediaExporter.cleanup(urls)
                return
            }
            activeController = nil
            controller.completionWithItemsHandler = nil
            presenter.dismiss(animated: false) {
                withExtendedLifetime(retainedPayloads) { MobileMediaExporter.cleanup(urls) }
            }
        }

        private func presentIfPossible(from presenter: HostController) {
            guard activeController == nil,
                presenter.viewIfLoaded?.window != nil,
                presenter.presentedViewController == nil,
                let pendingPayload,
                let payloadBinding
            else {
                return
            }
            self.pendingPayload = nil
            let controller = prepareController(
                for: pendingPayload,
                binding: payloadBinding,
                presenter: presenter
            )
            presenter.present(controller, animated: true)
        }

        private func complete(payloadID: UUID) {
            guard activePayload?.id == payloadID else { return }
            let urls = activePayload?.urls ?? []
            let completionURL = activePayload?.completionURL
            activePayload = nil
            activeController = nil
            MobileMediaExporter.cleanup(urls)

            if let payloadBinding, payloadBinding.wrappedValue?.id == payloadID {
                payloadBinding.wrappedValue = nil
            }
            payloadBinding = nil
            if let completionURL {
                UIApplication.shared.open(completionURL)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> HostController {
        let presenter = HostController()
        presenter.onAppearance = { [weak presenter, weak coordinator = context.coordinator] in
            guard let presenter else { return }
            coordinator?.hostDidAppear(presenter)
        }
        return presenter
    }

    func updateUIViewController(_ presenter: HostController, context: Context) {
        context.coordinator.update(payload: payload, binding: $payload, presenter: presenter)
    }

    static func dismantleUIViewController(_ presenter: HostController, coordinator: Coordinator) {
        presenter.onAppearance = nil
        coordinator.dismantle(presenter: presenter)
    }
}
