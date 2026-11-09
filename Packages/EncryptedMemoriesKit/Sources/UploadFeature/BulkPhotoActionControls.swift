import PhotosCore
import SwiftUI
import UploadCore

/// One fixed area for consent, progress and the acknowledged result. Closing its host never cancels a run.
/// Back Up Again and Restore All share it; only their approved copy differs.
public struct BulkPhotoActionControls: View {
    private let runner: BulkPhotoActionRunner
    private let action: BulkPhotoActionRunner.Action
    private let count: Int
    private let availability: @MainActor () -> Bool
    private let ownsActivity: @MainActor () -> Bool
    private let prepare: @MainActor () async -> BulkPhotoActionRunner.Confirmation?
    private let start: @MainActor (BulkPhotoActionRunner.Confirmation) -> Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPreparing = false
    @State private var pending: BulkPhotoActionRunner.Confirmation?
    @State private var showsConfirmation = false

    public init(
        runner: BulkPhotoActionRunner, action: BulkPhotoActionRunner.Action = .backUpAgain, count: Int,
        isAvailable: @escaping @MainActor () -> Bool,
        ownsActivity: @escaping @MainActor () -> Bool = { true },
        prepare: @escaping @MainActor () async -> BulkPhotoActionRunner.Confirmation?,
        start: @escaping @MainActor (BulkPhotoActionRunner.Confirmation) -> Bool
    ) {
        self.runner = runner
        self.action = action
        self.count = count
        availability = isAvailable
        self.ownsActivity = ownsActivity
        self.prepare = prepare
        self.start = start
    }

    public var body: some View {
        VStack(spacing: 0) {
            if runner.isRunning, ownsActivity() {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progress)
                        .accessibilityIdentifier("backup.bulk.progress")
                    ProgressView(value: Double(runner.processed), total: Double(max(1, runner.total)))
                    Text(
                        outcome(
                            completed: runner.completed, total: runner.total,
                            stayed: runner.processed - runner.completed)
                    )
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.caption)
                    Button(L10n.string("action.cancel")) { runner.cancel() }
                        .accessibilityIdentifier("backup.bulk.cancel")
                }
                .padding()
                .background(.bar)
            } else if let summary = runner.summary, ownsActivity() {
                VStack(alignment: .leading, spacing: 8) {
                    if summary.cancelled { Text(L10n.string("backup.bulk_cancelled")) }
                    Text(outcome(completed: summary.completed, total: summary.total, stayed: summary.stayed))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("backup.bulk.result")
                    Text(detail).font(.caption)
                    Button(L10n.string("action.ok")) { runner.dismissSummary() }
                        .accessibilityLabel(L10n.string("backup.bulk_dismiss_result"))
                        .accessibilityIdentifier("backup.bulk.dismissResult")
                }
                .padding()
                .background(.bar)
            } else if count > 0, !isPreparing {
                let layout =
                    dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Text(
                        count == 1
                            ? L10n.string("backup.bulk_count_one \(number(count))")
                            : L10n.string("backup.bulk_count_other \(number(count))")
                    )
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backup.bulk.count")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Button(actionTitle) { isPreparing = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isAvailable)
                        .accessibilityIdentifier("backup.bulk.backUpAgain")
                }
                .padding()
                .background(.bar)
            }
        }
        .alert(confirmationTitle, isPresented: $showsConfirmation, presenting: pending) { confirmation in
            Button(confirmTitle) {
                _ = start(confirmation)
                pending = nil
            }
            .accessibilityIdentifier("backup.bulk.confirm")
            Button(L10n.string("action.cancel"), role: .cancel) { clearConfirmation() }
        } message: { _ in
            Text(confirmationMessage)
        }
        .onChange(of: showsConfirmation) { _, visible in
            if !visible { clearConfirmation() }
        }
        .onChange(of: runner.confirmation?.id) { _, id in
            if id == nil { showsConfirmation = false }
        }
        .onChange(of: isAvailable) { _, available in
            if !available {
                isPreparing = false
                clearConfirmation()
            }
        }
        .onDisappear {
            isPreparing = false
            clearConfirmation()
        }
        .task(id: isPreparing) {
            guard isPreparing, isAvailable else { return }
            let confirmation = await prepare()
            guard !Task.isCancelled else { return }
            isPreparing = false
            guard isAvailable else {
                clearConfirmation()
                return
            }
            if let confirmation {
                pending = confirmation
                showsConfirmation = true
            }
        }
    }

    private var isAvailable: Bool { availability() }

    private var confirmationTitle: String {
        let total = pending?.count ?? 0
        switch (action, total == 1) {
        case (.backUpAgain, true): return L10n.string("backup.bulk_title_one \(number(total))")
        case (.backUpAgain, false): return L10n.string("backup.bulk_title_other \(number(total))")
        case (.restore, true): return L10n.string("albumsync.bulk_title_one \(number(total))")
        case (.restore, false): return L10n.string("albumsync.bulk_title_other \(number(total))")
        }
    }

    private var actionTitle: String {
        switch action {
        case .backUpAgain: L10n.string("backup.bulk_action \(number(count))")
        case .restore: L10n.string("albumsync.bulk_action \(number(count))")
        }
    }

    private var confirmTitle: String {
        switch action {
        case .backUpAgain: L10n.string("backup.back_up_again")
        case .restore: L10n.string("contextmenu.restore")
        }
    }

    private var confirmationMessage: String {
        switch action {
        case .backUpAgain: L10n.string("backup.bulk_message")
        case .restore: L10n.string("albumsync.bulk_message")
        }
    }

    /// Back Up Again only queues photos; a restore never means that the album already contains them.
    private var detail: String {
        switch action {
        case .backUpAgain: L10n.string("backup.bulk_queued_detail")
        case .restore: L10n.string("albumsync.bulk_restored_detail")
        }
    }

    private var progress: String {
        runner.total == 1
            ? L10n.string("backup.bulk_progress_one \(number(runner.processed)) \(number(runner.total))")
            : L10n.string("backup.bulk_progress_other \(number(runner.processed)) \(number(runner.total))")
    }

    private func outcome(completed: Int, total: Int, stayed: Int) -> String {
        let (done, all, left) = (number(completed), number(total), number(stayed))
        switch (action, total == 1) {
        case (.backUpAgain, true): return L10n.string("backup.bulk_outcome_one \(done) \(all) \(left)")
        case (.backUpAgain, false): return L10n.string("backup.bulk_outcome_other \(done) \(all) \(left)")
        case (.restore, true): return L10n.string("albumsync.bulk_outcome_one \(done) \(all) \(left)")
        case (.restore, false): return L10n.string("albumsync.bulk_outcome_other \(done) \(all) \(left)")
        }
    }

    private func number(_ value: Int) -> String { value.formatted(.number) }

    private func clearConfirmation() {
        showsConfirmation = false
        pending = nil
        runner.dismissConfirmation()
    }
}
