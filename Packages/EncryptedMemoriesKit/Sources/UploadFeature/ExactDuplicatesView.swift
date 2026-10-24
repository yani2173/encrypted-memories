import DesignSystemCore
import PhotosCore
import SwiftUI
import UploadCore

/// The Duplicates route of macOS, iOS, and iPadOS: groups of exact copies, one section per group. The shared
/// `ExactDuplicatesModel` owns the groups, the photo to keep, and the merges; this view renders them with a native
/// list and dialogs. The host owns the Merge All toolbar button and sets `confirmsMergeAll`, draws each photo, and
/// opens a photo of a group in its viewer.
public struct ExactDuplicatesView<Cover: View>: View {
    private let model: ExactDuplicatesModel
    @Binding private var confirmsMergeAll: Bool
    private let accent: Color
    private let cornerRadius: CGFloat
    private let canOpen: (PhotoUID) -> Bool
    private let libraryRevision: UInt64
    private let onOpen: (PhotoUID, String) -> Void
    private let cover: (PhotoUID) -> Cover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `accent` colors the checkmark and the border of the photo to keep.
    /// `cornerRadius` is the corner radius of `cover`. `canOpen` tells whether the library shows a photo yet, so
    /// the viewer can open it; a host whose library is not observed passes a `libraryRevision` that changes with the
    /// photos it shows, so a copy that was not ready redraws. `onOpen` receives a photo and the ID of its group.
    public init(
        model: ExactDuplicatesModel, confirmsMergeAll: Binding<Bool>, accent: Color, cornerRadius: CGFloat,
        canOpen: @escaping (PhotoUID) -> Bool = { _ in true }, libraryRevision: UInt64 = 0,
        onOpen: @escaping (PhotoUID, String) -> Void, @ViewBuilder cover: @escaping (PhotoUID) -> Cover
    ) {
        self.model = model
        _confirmsMergeAll = confirmsMergeAll
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.canOpen = canOpen
        self.libraryRevision = libraryRevision
        self.onOpen = onOpen
        self.cover = cover
    }

    public var body: some View {
        content
            .alert(model.mergeAllTitle, isPresented: $confirmsMergeAll) {
                Button(model.mergeAllConfirmTitle) {
                    Task { await model.mergeAll() }
                }
                .disabled(!model.canMerge)
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
                if let message = model.notice?.message, !message.isEmpty { Text(message) }
            }
            .task { await model.load(checkAllGroups: true) }
            .onDisappear { model.screenDisappeared() }
    }

    /// The waiting and empty states keep a readable width, so a wide Mac window does not stretch their text.
    private static var readableWidth: CGFloat { 600 }

    @ViewBuilder private var content: some View {
        if model.isCheckingGroups {
            loadingContent(model.checkingGroupsLine)
        } else {
            checkedContent
        }
    }

    @ViewBuilder private var checkedContent: some View {
        switch model.content {
        case .loading:
            loadingContent(model.loadingLine)
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.icloud")
            } actions: {
                RetryButton(.prominent) { Task { await model.load() } }
            }
            .frame(maxWidth: Self.readableWidth)
        case .noDuplicates:
            let copy = model.emptyStateCopy
            ContentUnavailableView(copy.title, systemImage: copy.systemImage, description: Text(copy.description))
                .frame(maxWidth: Self.readableWidth)
        case .stillChecking:
            let copy = model.emptyStateCopy
            ContentUnavailableView {
                Label(copy.title, systemImage: copy.systemImage)
            } description: {
                Text(copy.description)
            } actions: {
                if let line = model.checkLine {
                    progressRow(line, showsTitle: false)
                        .accessibilityIdentifier("duplicates.checkProgress")
                }
            }
            .frame(maxWidth: Self.readableWidth)
        case .groups:
            // Progress of the check changes this view often; the list compares equal and keeps its rows.
            ExactDuplicatesGroupList(
                model: model, accent: accent, cornerRadius: cornerRadius, reduceMotion: reduceMotion, canOpen: canOpen,
                libraryRevision: libraryRevision, onOpen: onOpen, cover: cover
            )
            .equatable()
        }
    }

    private func loadingContent(_ line: ExactDuplicatesModel.ProgressLine) -> some View {
        ContentUnavailableView {
            Label(line.title, systemImage: "square.on.square")
        } description: {
            Text(L10n.string("duplicates.loading_message"))
        } actions: {
            progressRow(line, showsTitle: false)
        }
        .frame(maxWidth: Self.readableWidth)
        .accessibilityIdentifier("duplicates.loading")
    }

    private func progressRow(_ line: ExactDuplicatesModel.ProgressLine, showsTitle: Bool = true) -> some View {
        ActivityProgressStateLayout {
            ExactDuplicatesProgressRow(line: line, showsTitle: showsTitle, alignment: .center)
        }
    }
}

/// One progress line of the screen. Without its title, the surrounding view shows the title. With `stop`, a Stop
/// button follows the line; it stays disabled after the person stopped. `identifier` names the line only, so the Stop
/// button keeps its own.
private struct ExactDuplicatesProgressRow: View {
    let line: ExactDuplicatesModel.ProgressLine
    var showsTitle = true
    var alignment: HorizontalAlignment = .leading
    var identifier: String?
    var stop: (() -> Void)?
    var canStop = true

    var body: some View {
        let row = ActivityProgressRow(
            title: showsTitle ? line.title : nil, detail: line.detail, fraction: line.fraction,
            showsIndeterminateProgress: true, alignment: alignment, accessibilityName: line.title
        )
        .accessibilityIdentifier(identifier ?? "")
        if let stop {
            HStack(alignment: .center, spacing: 12) {
                row
                Button(L10n.string("duplicates.stop"), action: stop)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(!canStop)
                    .accessibilityIdentifier("duplicates.stopMerge")
            }
        } else {
            row
        }
    }
}

/// The groups in one lazy column on every platform: rounded cards on the grouped background on iPhone and iPad, as an
/// inset grouped list draws them, and a calm column with dividers on the Mac. A `List` with one section per group
/// compared every row on the main thread for each change of the model; on the Mac 1,500 groups stopped scrolling for
/// seconds, and on iPhone and iPad the list kept every section in memory and redrew more than the shown rows.
///
/// Only the groups and whether a merge can start make this list evaluate again; the progress rows and the summary
/// observe the model on their own, and each part of a group redraws only when its group changes.
private struct ExactDuplicatesGroupList<Cover: View>: View, Equatable {
    let model: ExactDuplicatesModel
    let accent: Color
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    let canOpen: (PhotoUID) -> Bool
    let libraryRevision: UInt64
    let onOpen: (PhotoUID, String) -> Void
    let cover: (PhotoUID) -> Cover
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.accent == rhs.accent && lhs.cornerRadius == rhs.cornerRadius
            && lhs.reduceMotion == rhs.reduceMotion && lhs.libraryRevision == rhs.libraryRevision
    }

    /// The margin of the cards, and of their content inside them, as the inset grouped list uses it.
    private var margin: CGFloat {
        #if os(iOS)
            horizontalSizeClass == .regular ? 20 : 16
        #else
            24
        #endif
    }

    var body: some View {
        let canMerge = model.canMerge
        let groups = IndexedGroups(base: model.visibleGroups)
        let list = ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    ExactDuplicatesSummary(model: model)
                        .padding(.horizontal, DuplicatesLayout.cards ? margin : 0)
                    ExactDuplicatesStatusRows(model: model, margin: margin)
                }
                .padding(.bottom, DuplicatesLayout.cards ? 0 : 10)
                ForEach(groups, id: \.element.id) { index, group in
                    section(group, at: index, canMerge: canMerge)
                }
            }
            .padding(.horizontal, DuplicatesLayout.cards ? margin : 24)
            .padding(.vertical, 12)
            // A wide window or iPad adds margins instead of long rows.
            .frame(maxWidth: DuplicatesLayout.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
            return
                list
                .background(ProtonColor.groupedBackground.ignoresSafeArea())
                .refreshable { await model.load() }
        #else
            return list
        #endif
    }

    /// One group: its header, its copies, and its footer. The headers scroll with their groups, so none of them
    /// stays under the bars.
    @ViewBuilder
    private func section(_ group: ExactDuplicatesModel.Group, at index: Int, canMerge: Bool) -> some View {
        if DuplicatesLayout.cards {
            VStack(alignment: .leading, spacing: 8) {
                part(.header, of: group, at: index, canMerge: canMerge)
                    .padding(.horizontal, margin)
                part(.members, of: group, at: index, canMerge: canMerge)
                    .padding(.horizontal, margin)
                    .padding(.vertical, 15)
                    .duplicatesCard()
                part(.footer, of: group, at: index, canMerge: canMerge)
                    .font(.footnote)
                    .padding(.horizontal, margin)
            }
            .padding(.top, 16)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                part(.header, of: group, at: index, canMerge: canMerge)
                    .padding(.top, 8)
                part(.members, of: group, at: index, canMerge: canMerge)
                part(.footer, of: group, at: index, canMerge: canMerge)
                    .font(.subheadline)
            }
            .padding(.bottom, 14)
        }
    }

    private func part(
        _ part: ExactDuplicateGroupPart<Cover>.Part, of group: ExactDuplicatesModel.Group, at index: Int,
        canMerge: Bool
    ) -> some View {
        let model = model
        return ExactDuplicateGroupPart(
            part: part, group: group, index: index, canMerge: canMerge, accent: accent, cornerRadius: cornerRadius,
            reduceMotion: reduceMotion, libraryRevision: libraryRevision,
            actions: ExactDuplicateGroupActions(
                canOpen: canOpen,
                open: onOpen,
                keep: { model.keep($0, inGroup: $1) },
                merge: { groupID in Task { await model.merge(groupID: groupID) } },
                appeared: { model.groupAppeared($0) }),
            cover: cover
        )
        .equatable()
    }
}

/// The look of the column per platform: the inset grouped cards of iPhone and iPad, or the Mac column.
private enum DuplicatesLayout {
    #if os(iOS)
        static let cards = true
        static let maxWidth: CGFloat = .infinity
        /// The titles of the summary and of each group, as the headers of an inset grouped list show them.
        static let titleFont = Font.headline
        static let titleStyle = HierarchicalShapeStyle.secondary
        static let cardRadius: CGFloat = 26
    #else
        static let cards = false
        static let maxWidth: CGFloat = 880
        static let titleFont = Font.headline
        static let titleStyle = HierarchicalShapeStyle.primary
        static let cardRadius: CGFloat = 0
    #endif
}

extension View {
    /// A rounded card on the grouped background, as an inset grouped list draws a section.
    fileprivate func duplicatesCard() -> some View {
        #if os(iOS)
            background(
                ProtonColor.groupedCard,
                in: RoundedRectangle(cornerRadius: DuplicatesLayout.cardRadius, style: .continuous))
        #else
            self
        #endif
    }
}

/// The groups with their positions, without copying them.
private struct IndexedGroups: RandomAccessCollection {
    let base: [ExactDuplicatesModel.Group]
    var startIndex: Int { base.startIndex }
    var endIndex: Int { base.endIndex }
    subscript(position: Int) -> (offset: Int, element: ExactDuplicatesModel.Group) { (position, base[position]) }
}

/// The count of the copies with its explanation, and the space that merging all frees.
private struct ExactDuplicatesSummary: View {
    let model: ExactDuplicatesModel

    var body: some View {
        if let count = model.copyCountText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(count)
                        .font(DuplicatesLayout.titleFont)
                        .foregroundStyle(DuplicatesLayout.titleStyle)
                        .monospacedDigit()
                        .accessibilityIdentifier("duplicates.copyCount")
                    InfoButton(title: model.infoTitle, message: model.infoMessage)
                        .accessibilityIdentifier("duplicates.info")
                }
                if let freed = model.totalFreedText {
                    Text(freed)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("duplicates.totalFreed")
                }
            }
            .textCase(nil)
        }
    }
}

/// The state of the check and of the ranking above the groups: progress rows while they run, one line after a check
/// that could not read every photo, and a retry when the check stopped.
private struct ExactDuplicatesStatusRows: View {
    let model: ExactDuplicatesModel
    let margin: CGFloat

    private var hasRows: Bool {
        model.mergeAllLine != nil || model.checkLine != nil || model.stillCheckingNote != nil
            || model.rankingLine != nil || model.metadataCheckNote != nil
            || model.uncheckedNote != nil || model.checkFailedNote != nil
    }

    var body: some View {
        if hasRows {
            if DuplicatesLayout.cards {
                VStack(alignment: .leading, spacing: 12) { rows }
                    .padding(.horizontal, margin)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .duplicatesCard()
            } else {
                VStack(alignment: .leading, spacing: 12) { rows }
            }
        }
    }

    /// Stops Merge All after its running batch. Nil outside Merge All.
    private var stop: (() -> Void)? {
        guard model.isMergingAll else { return nil }
        let model = model
        return { model.stopMergeAll() }
    }

    @ViewBuilder private var rows: some View {
        if let line = model.mergeAllLine {
            ExactDuplicatesProgressRow(
                line: line, identifier: "duplicates.mergeProgress", stop: stop,
                canStop: model.canStopMergeAll)
        }
        if let line = model.checkLine {
            ExactDuplicatesProgressRow(line: line).accessibilityIdentifier("duplicates.checkProgress")
        }
        if let note = model.stillCheckingNote {
            Label(note, systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let line = model.rankingLine {
            // Merge All ranks the groups that nobody scrolled to first; Stop already applies.
            ExactDuplicatesProgressRow(
                line: line, identifier: "duplicates.rankingProgress", stop: stop,
                canStop: model.canStopMergeAll)
        }
        if let note = model.metadataCheckNote {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("duplicates.metadataCheck")
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
            RetryButton(.compact) { Task { await model.load() } }
        }
    }
}

/// What a group can ask of the model. The parts of a group call these instead of reading the model, so a change of
/// another group never evaluates them again.
private struct ExactDuplicateGroupActions {
    /// The library shows the photo, so the viewer can open it.
    let canOpen: (PhotoUID) -> Bool
    let open: (PhotoUID, String) -> Void
    let keep: (PhotoUID, String) -> Void
    let merge: (String) -> Void
    let appeared: (String) -> Void
}

/// One part of a group, shared by both containers: its header with the date and Merge, its copies, or its footer.
/// It depends only on its own group, so it redraws when that group changes and stays when another one does.
private struct ExactDuplicateGroupPart<Cover: View>: View, Equatable {
    enum Part { case header, members, footer }

    let part: Part
    let group: ExactDuplicatesModel.Group
    let index: Int
    let canMerge: Bool
    let accent: Color
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    /// Changes when the library shows other photos, so whether a copy can open is read again.
    let libraryRevision: UInt64
    let actions: ExactDuplicateGroupActions
    let cover: (PhotoUID) -> Cover

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.part == rhs.part && lhs.group == rhs.group && lhs.index == rhs.index && lhs.canMerge == rhs.canMerge
            && lhs.accent == rhs.accent && lhs.cornerRadius == rhs.cornerRadius && lhs.reduceMotion == rhs.reduceMotion
            && lhs.libraryRevision == rhs.libraryRevision
    }

    /// As checked facts arrive, the group's badges, its reason, and a moved checkmark fade in.
    /// Without motion, they appear at once.
    private var factsAnimation: Animation? { reduceMotion ? nil : .default }

    var body: some View {
        switch part {
        case .header: header
        case .members:
            // Readiness is a value of the copies, so they redraw when the library shows a copy that was not ready.
            ExactDuplicateMembers(
                group: group, groupIndex: index, ready: Set(group.members.filter(actions.canOpen)), accent: accent,
                cornerRadius: cornerRadius, actions: actions, cover: cover
            )
            .accessibilityIdentifier("duplicates.group.\(index)")
            // Only the groups that the person scrolls to read their facts.
            .onAppear { actions.appeared(group.id) }
            .animation(factsAnimation, value: group.isRanked)
            .animation(factsAnimation, value: group.kept)
        case .footer:
            footer.animation(factsAnimation, value: group.isRanked)
        }
    }

    /// The capture date of the group and its Merge button.
    private var header: some View {
        HStack(alignment: .center) {
            Text(group.title)
                .font(DuplicatesLayout.titleFont)
                .foregroundStyle(DuplicatesLayout.titleStyle)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityIdentifier("duplicates.date.\(index)")
            Spacer(minLength: 12)
            Button(L10n.string("duplicates.merge")) { actions.merge(group.id) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(!canMerge)
                .accessibilityIdentifier("duplicates.merge.\(index)")
        }
        .textCase(nil)
    }

    /// Why the checked copy stays and what the merge frees, and after a merge why duplicates stayed.
    @ViewBuilder private var footer: some View {
        if group.footerText != nil || group.keptReasonMessage != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let footer = group.footerText {
                    Text(footer)
                        .monospacedDigit()
                        .accessibilityIdentifier("duplicates.footer.\(index)")
                }
                if let reason = group.keptReasonMessage {
                    Text(reason)
                        .accessibilityIdentifier("duplicates.keptReason.\(index)")
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// The copies of one group, side by side. A tap or click opens the photo; the context menu keeps it.
private struct ExactDuplicateMembers<Cover: View>: View {
    let group: ExactDuplicatesModel.Group
    let groupIndex: Int
    /// The copies that the library shows, so the viewer can open them.
    let ready: Set<PhotoUID>
    let accent: Color
    let cornerRadius: CGFloat
    let actions: ExactDuplicateGroupActions
    let cover: (PhotoUID) -> Cover
    /// The width of the copies and of the space for them. The row scrolls only when the copies are wider.
    @State private var contentWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        // A row that fits never takes a scroll gesture: a vertical one over it scrolls the list, not the row.
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(group.members.enumerated()), id: \.element) { index, uid in
                    let isKept = uid == group.kept
                    let keepTitle = group.keepTitle(for: uid)
                    member(uid, isKept: isKept, keepTitle: keepTitle)
                        .accessibilityLabel(group.accessibilityLabel(of: uid))
                        .accessibilityAddTraits(isKept ? .isSelected : [])
                        .accessibilityAction(named: Text(keepTitle)) { actions.keep(uid, group.id) }
                        .accessibilityIdentifier("duplicates.member.\(groupIndex).\(index)")
                }
            }
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                contentWidth = $0
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .scrollDisabled(contentWidth <= availableWidth + 0.5)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .accessibilityElement(children: .contain)
    }

    /// A tap or click opens the photo; a long press or a secondary click offers Keep This Copy.
    @ViewBuilder private func member(_ uid: PhotoUID, isKept: Bool, keepTitle: String) -> some View {
        // Right after launch the library may not show a copy yet; its tile shows that it is not ready.
        let isReady = ready.contains(uid)
        let open = { if isReady { actions.open(uid, group.id) } }
        let tile = ExactDuplicateTile(
            group: group, member: uid, accent: accent, cornerRadius: cornerRadius, isReady: isReady,
            cover: cover(uid))
        let keep = Button {
            actions.keep(uid, group.id)
        } label: {
            Label(keepTitle, systemImage: "checkmark.circle")
        }
        .disabled(isKept)
        .accessibilityIdentifier("duplicates.keepMenu")
        #if os(iOS)
            // A context menu inside a List row becomes the menu of the whole row, so a long press on any copy showed
            // the menu of the first one. A menu with a primary action belongs to its own copy.
            Menu {
                keep
            } label: {
                tile
            } primaryAction: {
                open()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        #else
            Button(action: open) {
                tile
            }
            .buttonStyle(.plain)
            .contextMenu { keep }
        #endif
    }
}

/// One copy: equal to the others, its size at the bottom right and its badges at the bottom left.
/// The copy that a merge keeps carries a checkmark and a thin accent border.
private struct ExactDuplicateTile<Cover: View>: View {
    let group: ExactDuplicatesModel.Group
    let member: PhotoUID
    let accent: Color
    let cornerRadius: CGFloat
    /// The library shows the copy, so the viewer can open it.
    let isReady: Bool
    let cover: Cover

    /// A small thumbnail shows at most two badges; the rest is a count.
    private static var visibleBadges: Int { 2 }

    var body: some View {
        let isKept = member == group.kept
        cover
            .overlay {
                if !isReady { ProgressView().controlSize(.small) }
            }
            .overlay(alignment: .bottomLeading) { badges }
            .overlay(alignment: .bottomTrailing) {
                if let size = group.byteSize(of: member) {
                    Text(ExactDuplicatesModel.byteText(size))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .modifier(ThumbnailText())
                }
            }
            .overlay(alignment: .topTrailing) {
                if isKept {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, accent)
                        .shadow(color: .black.opacity(0.3), radius: 1.5)
                        .padding(5)
                }
            }
            .overlay {
                if isKept {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(accent, lineWidth: 2)
                }
            }
    }

    @ViewBuilder private var badges: some View {
        let badges = group.badges(of: member)
        if !badges.isEmpty {
            HStack(spacing: 3) {
                ForEach(badges.prefix(Self.visibleBadges), id: \.self) { badge in
                    Image(systemName: Self.systemImage(of: badge))
                }
                if badges.count > Self.visibleBadges {
                    Text(verbatim: "+\(badges.count - Self.visibleBadges)")
                        .monospacedDigit()
                }
            }
            .font(.caption2.weight(.semibold))
            .modifier(ThumbnailText())
        }
    }

    private static func systemImage(of badge: ExactDuplicateBadge) -> String {
        switch badge {
        case .shared: return "person.2.fill"
        case .album: return "rectangle.stack"
        case .favorite: return "heart.fill"
        case .backedUpHere:
            #if os(macOS)
                return "macbook"
            #else
                return "iphone"
            #endif
        }
    }
}

/// White text on a photo with a subtle shadow, so the size stays readable on a thumbnail.
private struct ThumbnailText: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
    }
}
