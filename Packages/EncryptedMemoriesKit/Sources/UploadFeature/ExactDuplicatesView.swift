import DesignSystemCore
import PhotosCore
import SwiftUI
import UploadCore

/// The Duplicates route of macOS, iOS, and iPadOS: groups of exact copies, one section per group. The shared
/// `ExactDuplicatesModel` owns the groups, the photo to keep, and the merges; this view renders them with a native
/// list and dialogs. The host owns the toolbar buttons Select, Merge All, and Merge Selected, and it sets
/// `confirmsMergeAll` and `confirmsMergeSelected`. It draws each photo and presents its viewer when the person opens a
/// copy larger.
public struct ExactDuplicatesView<Cover: View>: View {
    private let model: ExactDuplicatesModel
    @Binding private var confirmsMergeAll: Bool
    @Binding private var confirmsMergeSelected: Bool
    private let accent: Color
    private let item: (PhotoUID) -> PhotoItem?
    private let open: ([PhotoItem], Int) -> Void
    private let cover: (PhotoUID) -> Cover

    /// `accent` colors the checkmark of the photo to keep and the progress indicator. `item` gives the library item
    /// of a copy, for its video length and the viewer. `open` presents the viewer with the copies of one group,
    /// starting at the copy at the index, so the person pages through them, zooms into photos, and plays videos.
    public init(
        model: ExactDuplicatesModel, confirmsMergeAll: Binding<Bool>, confirmsMergeSelected: Binding<Bool>,
        accent: Color, item: @escaping (PhotoUID) -> PhotoItem?, open: @escaping ([PhotoItem], Int) -> Void,
        @ViewBuilder cover: @escaping (PhotoUID) -> Cover
    ) {
        self.model = model
        _confirmsMergeAll = confirmsMergeAll
        _confirmsMergeSelected = confirmsMergeSelected
        self.accent = accent
        self.item = item
        self.open = open
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
            .confirmationDialog(
                model.mergeSelectedTitle, isPresented: $confirmsMergeSelected, titleVisibility: .visible
            ) {
                Button(L10n.string("duplicates.merge"), role: .destructive) {
                    Task { await model.mergeSelected() }
                }
                .accessibilityIdentifier("duplicates.mergeSelected.dialog")
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(model.mergeSelectedMessage)
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
            let line = model.loadingLine
            ContentUnavailableView {
                Label(line.title, systemImage: "square.on.square")
            } actions: {
                progressRow(line, showsTitle: false)
                    .frame(maxWidth: 320)
            }
            .accessibilityIdentifier("duplicates.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.icloud")
            } actions: {
                retryButton
            }
        case .noDuplicates:
            let copy = model.emptyStateCopy
            ContentUnavailableView(copy.title, systemImage: copy.systemImage, description: Text(copy.description))
        case .stillChecking:
            let copy = model.emptyStateCopy
            ContentUnavailableView {
                Label(copy.title, systemImage: copy.systemImage)
            } description: {
                Text(copy.description)
            } actions: {
                if let line = model.checkLine {
                    progressRow(line, showsTitle: false)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("duplicates.checkProgress")
                }
            }
        case .groups:
            groupList
        }
    }

    /// The shared progress row. Without its title, the surrounding view shows the title.
    private func progressRow(_ line: ExactDuplicatesModel.ProgressLine, showsTitle: Bool = true) -> some View {
        ActivityProgressRow(
            title: showsTitle ? line.title : nil, detail: line.detail, fraction: line.fraction,
            showsIndeterminateProgress: true
        )
        .tint(accent)
    }

    /// The rows above the groups: the progress of a merge, the selected groups while the person selects, the switch
    /// that shows only pairs, the progress of the check and of the ranking, one line after a check that could not read
    /// every photo, and a retry when the check stopped.
    @ViewBuilder private var statusRows: some View {
        if let line = model.mergeLine {
            progressRow(line).accessibilityIdentifier("duplicates.mergeProgress")
        }
        if model.isSelecting {
            HStack {
                Text(model.selectionText).accessibilityIdentifier("duplicates.selectionCount")
                Spacer()
                Button(L10n.string(model.isAllSelected ? "duplicates.deselect_all" : "duplicates.select_all")) {
                    model.toggleSelectAll()
                }
                .buttonStyle(.borderless)
                .disabled(model.isMerging)
                .accessibilityIdentifier("duplicates.selectAll")
            }
        }
        if model.hasLargerGroups {
            Toggle(
                L10n.string("duplicates.pairs_only"),
                isOn: Binding(get: { model.showsOnlyPairs }, set: { model.showsOnlyPairs = $0 })
            )
            .accessibilityIdentifier("duplicates.pairsOnly")
            if let note = model.hiddenGroupsNote {
                Label(note, systemImage: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("duplicates.hiddenGroups")
            }
        }
        if let line = model.checkLine {
            progressRow(line).accessibilityIdentifier("duplicates.checkProgress")
        }
        if let note = model.stillCheckingNote {
            Label(note, systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let line = model.rankingLine {
            progressRow(line).accessibilityIdentifier("duplicates.rankingProgress")
        }
        if let note = model.uncheckedNote {
            Label(note, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("duplicates.unchecked")
        }
        if let note = model.checkFailedNote {
            Label(note, systemImage: "exclamationmark.icloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(L10n.string("action.retry")) { Task { await model.load() } }
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
            Section {
                statusRows
            } header: {
                if let count = model.groupCountText {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count).accessibilityIdentifier("duplicates.groupCount")
                        if let freed = model.totalFreedText {
                            Text(freed)
                                .monospacedDigit()
                                .accessibilityIdentifier("duplicates.totalFreed")
                        }
                        if let note = model.totalFreedNote {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("duplicates.totalFreedNote")
                        }
                    }
                }
            }
            ForEach(Array(model.shownGroups.enumerated()), id: \.element.id) { index, group in
                Section {
                    ExactDuplicateMembers(
                        model: model, group: group, groupIndex: index, accent: accent, item: item, open: open,
                        cover: cover
                    )
                    .accessibilityIdentifier("duplicates.group.\(index)")
                    // Only the groups that the person scrolls to read their facts.
                    .onAppear { model.groupAppeared(group.id) }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        if model.isSelecting {
                            selectionButton(for: group, index: index)
                        }
                        Text(L10n.string("duplicates.group_title \(group.members.count)"))
                        if let freed = group.freedText {
                            Text(freed)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityIdentifier("duplicates.freed.\(index)")
                        }
                        Spacer()
                        if !model.isSelecting {
                            Button(L10n.string("duplicates.merge")) {
                                Task { await model.merge(groupID: group.id) }
                            }
                            .disabled(!model.canMerge)
                            .accessibilityIdentifier("duplicates.merge.\(index)")
                        }
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

    /// The circle that selects a group while the person selects the groups to merge.
    private func selectionButton(for group: ExactDuplicatesModel.Group, index: Int) -> some View {
        let isSelected = model.selectedGroupIDs.contains(group.id)
        return Button {
            model.toggleSelection(group.id)
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? accent : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(model.isMerging)
        .accessibilityLabel(L10n.string("duplicates.select_group"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("duplicates.select.\(index)")
    }
}

/// The copies of one group. A click or tap keeps that photo; a checkmark marks the photo that the merge keeps. The
/// button in the corner, the context menu, and an accessibility action open the copy larger in the viewer of the host,
/// which pages through every copy of the group and plays a video. A badge shows the length of a video and marks a Live
/// Photo.
private struct ExactDuplicateMembers<Cover: View>: View {
    let model: ExactDuplicatesModel
    let group: ExactDuplicatesModel.Group
    let groupIndex: Int
    let accent: Color
    let item: (PhotoUID) -> PhotoItem?
    let open: ([PhotoItem], Int) -> Void
    let cover: (PhotoUID) -> Cover

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(group.members.enumerated()), id: \.element) { index, uid in
                    member(uid, index: index)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
    }

    private func member(_ uid: PhotoUID, index: Int) -> some View {
        let isKept = uid == group.kept
        let media = item(uid)
        let viewer = group.viewerItems(opening: uid, item: item)
        let isVideo = media?.isVideo == true
        let openTitle = L10n.string(isVideo ? "duplicates.play_video" : "duplicates.show_larger")
        let openSymbol = isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right"
        return Button {
            model.keep(uid, inGroup: group.id)
        } label: {
            cover(uid)
                .overlay(alignment: .bottomLeading) {
                    if let media { ExactDuplicateMediaBadge(item: media) }
                }
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
        .accessibilityValue(media.map(Self.mediaDescription) ?? "")
        .accessibilityHint(isKept ? "" : L10n.string("duplicates.member_hint"))
        .accessibilityAddTraits(isKept ? .isSelected : [])
        .accessibilityActions {
            if let viewer {
                Button(openTitle) { open(viewer.items, viewer.index) }
            }
        }
        .accessibilityIdentifier("duplicates.member.\(groupIndex).\(index)")
        .contextMenu {
            if let viewer {
                Button(openTitle, systemImage: openSymbol) { open(viewer.items, viewer.index) }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let viewer {
                Button {
                    open(viewer.items, viewer.index)
                } label: {
                    Image(systemName: openSymbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: Self.openButtonSize, minHeight: Self.openButtonSize)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(openTitle)
                .accessibilityLabel(openTitle)
                .accessibilityIdentifier("duplicates.open.\(groupIndex).\(index)")
            }
        }
    }

    /// The kind of a copy for VoiceOver: a video with its length, or a Live Photo. Empty for a still photo.
    private static func mediaDescription(_ item: PhotoItem) -> String {
        if item.isVideo {
            return [L10n.string("a11y.video"), item.durationText].compactMap { $0 }.joined(separator: ", ")
        }
        return item.isLivePhoto ? L10n.string("viewer.live_photo_a11y") : ""
    }

    #if os(iOS)
        private static var checkmarkFont: Font { .title3 }
        private static var openButtonSize: CGFloat { 28 }
    #else
        private static var checkmarkFont: Font { .title2 }
        private static var openButtonSize: CGFloat { 24 }
    #endif
}

/// The length of a video, or the mark of a Live Photo, in the corner of its cover.
private struct ExactDuplicateMediaBadge: View {
    let item: PhotoItem

    var body: some View {
        if item.isVideo {
            badge(systemImage: PhotoTag.videos.systemImage, text: item.durationText)
        } else if item.isLivePhoto {
            badge(systemImage: PhotoTag.livePhotos.systemImage, text: nil)
        }
    }

    private func badge(systemImage: String, text: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            if let text {
                Text(text).monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(6)
        .accessibilityHidden(true)
    }
}
