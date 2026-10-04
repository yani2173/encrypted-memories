import PhotosCore
import SwiftUI
import UploadCore

/// The Duplicates route of macOS, iOS, and iPadOS: groups of exact copies, one section per group. The shared
/// `ExactDuplicatesModel` owns the groups, the photo to keep, and the merges; this view renders them with a native
/// list and dialogs. The host owns the Merge All toolbar button and sets `confirmsMergeAll`, and it draws each photo.
public struct ExactDuplicatesView<Cover: View>: View {
    private let model: ExactDuplicatesModel
    @Binding private var confirmsMergeAll: Bool
    private let accent: Color
    private let cover: (PhotoUID) -> Cover

    /// `accent` colors the checkmark of the photo to keep and the progress indicator.
    public init(
        model: ExactDuplicatesModel, confirmsMergeAll: Binding<Bool>, accent: Color,
        @ViewBuilder cover: @escaping (PhotoUID) -> Cover
    ) {
        self.model = model
        _confirmsMergeAll = confirmsMergeAll
        self.accent = accent
        self.cover = cover
    }

    public var body: some View {
        content
            .confirmationDialog(model.mergeAllTitle, isPresented: $confirmsMergeAll, titleVisibility: .visible) {
                Button(L10n.string("duplicates.merge_all"), role: .destructive) {
                    Task { await model.mergeAll() }
                }
                .accessibilityIdentifier("duplicates.mergeAll.dialog")
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(model.mergeAllMessage)
            }
            .alert(
                model.notice?.title ?? "",
                isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.dismissNotice() } })
            ) {
                Button(L10n.string("action.ok"), role: .cancel) { model.dismissNotice() }
            } message: {
                Text(model.notice?.message ?? "")
            }
            .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .loading:
            ProgressView().tint(accent)
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.icloud")
            } actions: {
                retryButton
            }
        case .noDuplicates, .stillChecking:
            let copy = model.emptyStateCopy
            ContentUnavailableView(copy.title, systemImage: copy.systemImage, description: Text(copy.description))
        case .groups:
            groupList
        }
    }

    @ViewBuilder private var retryButton: some View {
        let retry = Button(L10n.string("action.retry")) { Task { await model.load() } }
        #if os(iOS)
            retry.buttonStyle(.glassProminent)
        #else
            retry
        #endif
    }

    private var groupList: some View {
        let list = List {
            if let note = model.stillCheckingNote {
                Section {
                    Label(note, systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                Section {
                    ExactDuplicateMembers(model: model, group: group, groupIndex: index, accent: accent, cover: cover)
                        .accessibilityIdentifier("duplicates.group.\(index)")
                } header: {
                    HStack {
                        Text(L10n.string("duplicates.group_title \(group.members.count)"))
                        Spacer()
                        Button(L10n.string("duplicates.merge")) {
                            Task { await model.merge(groupID: group.id) }
                        }
                        .disabled(!model.canMerge)
                        .accessibilityIdentifier("duplicates.merge.\(index)")
                    }
                    .textCase(nil)
                } footer: {
                    if let reason = group.keptReasonMessage {
                        Text(reason)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("duplicates.keptReason.\(index)")
                    }
                }
            }
        }
        #if os(iOS)
            return list.listStyle(.insetGrouped).refreshable { await model.load() }
        #else
            return list.listStyle(.inset)
        #endif
    }
}

/// The copies of one group. A click or tap keeps that photo; a checkmark marks the photo that the merge keeps.
private struct ExactDuplicateMembers<Cover: View>: View {
    let model: ExactDuplicatesModel
    let group: ExactDuplicatesModel.Group
    let groupIndex: Int
    let accent: Color
    let cover: (PhotoUID) -> Cover

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(group.members.enumerated()), id: \.element) { index, uid in
                    let isKept = uid == group.kept
                    Button {
                        model.keep(uid, inGroup: group.id)
                    } label: {
                        cover(uid)
                            .overlay(alignment: .bottomTrailing) {
                                if isKept {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(Self.checkmarkFont)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, accent)
                                        .padding(6)
                                }
                            }
                            .opacity(isKept ? 1 : 0.75)
                    }
                    .buttonStyle(.plain)
                    .help(isKept ? "" : L10n.string("duplicates.member_hint"))
                    .accessibilityLabel(
                        isKept ? L10n.string("duplicates.member_kept") : L10n.string("duplicates.member_duplicate")
                    )
                    .accessibilityHint(isKept ? "" : L10n.string("duplicates.member_hint"))
                    .accessibilityAddTraits(isKept ? .isSelected : [])
                    .accessibilityIdentifier("duplicates.member.\(groupIndex).\(index)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
    }

    #if os(iOS)
        private static var checkmarkFont: Font { .title3 }
    #else
        private static var checkmarkFont: Font { .title2 }
    #endif
}
