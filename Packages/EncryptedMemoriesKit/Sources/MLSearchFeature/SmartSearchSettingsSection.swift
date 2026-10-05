import DesignSystemCore
import Foundation
import MLSearchCore
import PhotosCore
import SwiftUI

/// What the Smart Search section shows below its switch.
enum SmartSearchSettingsContent: Equatable {
    case off
    /// The device cannot run Smart Search. The switch stays off and disabled.
    case unsupported
    /// The switch is on and the model list loads; Smart Search then starts with the recommended model.
    case starting
    /// Smart Search runs but lost its model, for example when the catalog dropped it; the person picks one.
    case modelChoice
    case status
}

enum SmartSearchSettingsPolicy {
    /// The switch looks on while Smart Search starts, before anything is stored.
    static func isToggleOn(isEnabled: Bool, isStarting: Bool) -> Bool {
        isEnabled || isStarting
    }

    static func content(
        isSupported: Bool,
        isEnabled: Bool,
        hasSelectedModel: Bool,
        isStarting: Bool
    ) -> SmartSearchSettingsContent {
        // Enabled Smart Search stays manageable, so it can always be turned off.
        if isEnabled { return hasSelectedModel ? .status : .modelChoice }
        guard isSupported else { return .unsupported }
        return isStarting ? .starting : .off
    }

    /// Replacing a model that was activated rebuilds its index, so it asks first, also while that model is not
    /// loaded. Before the first model is ready, the choice only stops or skips a download.
    static func asksBeforeSwitching(hasActivatedModel: Bool) -> Bool {
        hasActivatedModel
    }
}

/// Shared Smart Search settings for macOS, iOS and iPadOS.
public struct SmartSearchSettingsSection: View {
    private let controller: MLSmartSearchController
    @State private var pendingModelSwitch: MLModelCatalogEntry?
    @State private var confirmingDisable = false
    @State private var pickingDeveloperArtifact = false
    @State private var developerInstallTarget: MLModelID?

    public init(controller: MLSmartSearchController) {
        self.controller = controller
    }

    public var body: some View {
        let snapshot = controller.snapshot
        let content = SmartSearchSettingsPolicy.content(
            isSupported: snapshot.isSupported,
            isEnabled: snapshot.isEnabled,
            hasSelectedModel: snapshot.selectedModelID != nil,
            isStarting: isStarting
        )
        Section {
            Toggle(isOn: enabledBinding) {
                Text(MLSmartSearchPresentation.productName)
            }
            // Removal must commit before Smart Search can be turned on again.
            .disabled(content == .unsupported || snapshot.phase == .deleting)
            .accessibilityIdentifier("smartsearch.toggle")

            switch content {
            case .off:
                EmptyView()
            case .unsupported:
                Text(L10n.string("mlsearch.unsupported_device"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .starting:
                modelStatusRows
            case .modelChoice:
                modelChoices
            case .status:
                statusRows
                modelStatusRows
                modelPicker
            }
        } footer: {
            Text(MLSmartSearchPresentation.privacyStatement)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.2), value: content)
        .alert(
            L10n.string("mlsearch.disable_confirm_title \(MLSmartSearchPresentation.productName)"),
            isPresented: $confirmingDisable
        ) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button(L10n.string("mlsearch.disable_confirm_action"), role: .destructive) {
                controller.disableAndPurge()
            }
        } message: {
            Text(L10n.string("mlsearch.disable_confirm_message"))
        }
        .alert(
            L10n.string("mlsearch.switch_confirm_title"),
            isPresented: Binding(
                get: { pendingModelSwitch != nil },
                set: { if !$0 { pendingModelSwitch = nil } }
            )
        ) {
            Button(L10n.string("mlsearch.switch_confirm_action")) {
                if let target = pendingModelSwitch {
                    activate(target)
                }
                pendingModelSwitch = nil
            }
            Button(L10n.string("action.cancel"), role: .cancel) { pendingModelSwitch = nil }
        } message: {
            Text(L10n.string("mlsearch.switch_confirm_message"))
        }
        .fileImporter(
            isPresented: $pickingDeveloperArtifact,
            allowedContentTypes: [.folder]
        ) { result in
            // The controller keeps the security scope open until installation completes.
            if case .success(let url) = result, let target = developerInstallTarget {
                controller.installDeveloperModel(from: url, for: target)
            }
            developerInstallTarget = nil
        }
    }

    /// The lifecycle owns a pending switch-on; the controller shows the person's latest tap until it arrives there.
    private var isStarting: Bool {
        controller.startSwitch.isStarting(controller.snapshot)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: {
                SmartSearchSettingsPolicy.isToggleOn(
                    isEnabled: controller.snapshot.isEnabled,
                    isStarting: isStarting
                )
            },
            set: { enable in
                if enable {
                    // Starts at once with the recommended model; the picker below changes it at any time.
                    controller.enableRecommended()
                } else if controller.snapshot.isEnabled {
                    confirmingDisable = true
                } else {
                    controller.cancelRecommendedEnable()
                }
            }
        )
    }

    // MARK: - Model choice

    /// Smart Search runs without a model: the recommended model first, one tap starts download and indexing.
    @ViewBuilder
    private var modelChoices: some View {
        let models = MLModelRecommendation.ordered(controller.snapshot.availableModels)
        if models.isEmpty {
            modelStatusRows
        } else {
            Text(L10n.string("mlsearch.model_choice_intro"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(models) { model in
                Button {
                    activate(model)
                } label: {
                    modelChoiceLabel(model, isRecommended: model.id == models.first?.id)
                }
                .buttonStyle(.plain)
                .disabled(controller.modelPresentation.isBusy)
                .accessibilityLabel(Text(L10n.string(dynamicKey: model.localizedMetadata.selectionTitleKey)))
                .accessibilityValue(Text(L10n.string(dynamicKey: model.localizedMetadata.selectionDescriptionKey)))
            }
            modelStatusRows
        }
    }

    private func modelChoiceLabel(_ model: MLModelCatalogEntry, isRecommended: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.string(dynamicKey: model.localizedMetadata.selectionTitleKey))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if isRecommended {
                        Text(L10n.string("mlsearch.model_recommended"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    Spacer(minLength: 8)
                    if let size = modelDownloadSize(model) {
                        Text(size)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(L10n.string(dynamicKey: model.localizedMetadata.selectionDescriptionKey))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }

    /// While Smart Search runs, the model is one compact row. It works during the first download too; replacing
    /// a model that already serves rebuilds its index and asks first.
    @ViewBuilder
    private var modelPicker: some View {
        let snapshot = controller.snapshot
        let models = MLModelRecommendation.ordered(snapshot.availableModels)
        if models.count > 1 {
            Picker(L10n.string("mlsearch.model_row"), selection: modelSelectionBinding) {
                ForEach(models) { model in
                    Text(L10n.string(dynamicKey: model.localizedMetadata.selectionTitleKey))
                        .tag(Optional(model.id))
                }
            }
            .disabled(!snapshot.allowsModelChoice)
        }
        if let selected = snapshot.availableModels.first(where: { $0.id == snapshot.selectedModelID }),
            selected.releaseTrack == .developerOnly
        {
            Text(MLSmartSearchPresentation.developerModelNote)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var modelSelectionBinding: Binding<MLModelID?> {
        Binding(
            get: { controller.snapshot.selectedModelID },
            set: { id in
                guard let id, id != controller.snapshot.selectedModelID,
                    let model = controller.snapshot.availableModels.first(where: { $0.id == id })
                else { return }
                if SmartSearchSettingsPolicy.asksBeforeSwitching(
                    hasActivatedModel: controller.snapshot.hasActivatedModel)
                {
                    pendingModelSwitch = model
                } else {
                    activate(model)
                }
            }
        )
    }

    // MARK: - Status

    @ViewBuilder
    private var modelStatusRows: some View {
        let presentation = controller.modelPresentation
        // The overall status already names a model step when no indexing runs; do not repeat it.
        if let status = presentation.statusText, status != controller.presentation.statusText {
            ActivityProgressRow(
                title: status, detail: presentation.detailText, fraction: presentation.progressFraction)
            if presentation.canRetry {
                Button {
                    controller.retry()
                } label: {
                    Label(L10n.string("action.retry"), systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        let presentation = controller.presentation

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusSummary(presentation)
            if let note = presentation.unavailableNote {
                InfoButton(title: L10n.string("mlsearch.unavailable_title"), message: note)
            }
        }

        if presentation.canRetry {
            Button {
                controller.retry()
            } label: {
                Label(L10n.string("action.retry"), systemImage: "arrow.clockwise")
            }
        }
    }

    private func statusSummary(_ presentation: MLSmartSearchPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.statusText)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = presentation.detailText {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ProgressView(value: presentation.progressFraction ?? 0)
                .progressViewStyle(.linear)
                .opacity(presentation.progressFraction == nil ? 0 : 1)
                .accessibilityHidden(presentation.progressFraction == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(presentation.statusText))
        .accessibilityValue(Text(presentation.detailText ?? ""))
    }

    private var statusSymbolName: String {
        if controller.presentation.presentsAsReady { return "checkmark.circle.fill" }
        switch controller.snapshot.indexingState {
        case .indexing: return "sparkles"
        case .waiting: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle, .ready: break
        }
        return switch controller.snapshot.phase {
        case .disabled: "minus.circle"
        case .loadingCatalog: "arrow.triangle.2.circlepath"
        case .selectingModel: "cpu"
        case .notInstalled: "arrow.down.circle"
        case .downloading: "arrow.down.circle.fill"
        case .verifying: "checkmark.shield"
        case .installing: "square.and.arrow.down"
        case .preparingModel: "cpu"
        case .indexing: "sparkles"
        case .waiting: "pause.circle"
        case .ready: "checkmark.circle.fill"
        case .switchingModel: "arrow.triangle.2.circlepath"
        case .deleting: "trash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        if controller.presentation.presentsAsReady { return .green }
        if case .failed = controller.snapshot.indexingState { return .orange }
        return switch controller.snapshot.phase {
        case .failed: .orange
        case .ready: .green
        default: .secondary
        }
    }

    // MARK: - Actions

    /// Starts Smart Search with `model`, or switches to it. A developer model without a hosted
    /// artifact asks for its local folder once Smart Search owns the selection.
    private func activate(_ model: MLModelCatalogEntry) {
        controller.enable(with: model.id)
        if model.releaseTrack == .developerOnly, !model.isDownloadable {
            developerInstallTarget = model.id
            pickingDeveloperArtifact = true
        }
    }

    private func modelDownloadSize(_ model: MLModelCatalogEntry) -> String? {
        guard let bytes = model.downloadPlan?.totalByteCount, bytes > 0 else { return nil }
        return L10n.fileSize(bytes)
    }
}
