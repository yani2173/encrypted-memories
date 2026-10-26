import DesignSystemCore
import Foundation
import MediaCacheUIKitAdapter
import Observation
import PhotosCore
import SwiftUI
import TimelineCore

/// On This Day state of the library tab. TimelineCore selects the memories off the main actor; this model keeps the
/// result for the current library and day, the browsing position, and the record of opened memories.
@MainActor @Observable final class MobileOnThisDayModel {
    /// Everything the selection depends on. A new library snapshot, day, calendar or time zone builds it again.
    struct Request: Equatable {
        let timelineRevision: UInt64
        let referenceDay: OnThisDayReferenceDay
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String

        init(timelineRevision: UInt64, reference: Date, calendar: Calendar) {
            self.timelineRevision = timelineRevision
            referenceDay = OnThisDayReferenceDay(date: reference, calendar: calendar)
            calendarIdentifier = calendar.identifier
            timeZoneIdentifier = calendar.timeZone.identifier
        }
    }

    /// The last built selection. It stays while a newer library snapshot of the same day builds, so the stacks do not
    /// flicker; a selection of another day is never shown.
    private(set) var memories: OnThisDayMemories?
    private var builtRequest: Request?
    var browser = OnThisDayBrowser()
    var isExpanded = false
    private(set) var seenRecord: OnThisDaySeenRecord?
    @ObservationIgnored private let seenStore = OnThisDaySeenStore()

    init() {
        seenRecord = seenStore.load()
    }

    func availability(for request: Request, authority: SourceInventoryAuthority, loadFailed: Bool)
        -> OnThisDayAvailability
    {
        let current = memories?.referenceDay == request.referenceDay ? memories : nil
        // A snapshot that is still building may not reach the stacks as complete.
        let builtAuthority = builtRequest == request ? authority : .cached
        return OnThisDayAvailability.resolve(memories: current, authority: builtAuthority, loadFailed: loadFailed)
    }

    func refresh(items: [PhotoItem], request: Request, reference: Date, calendar: Calendar) async {
        guard builtRequest != request else { return }
        guard let built = try? await OnThisDayMemories.build(items: items, reference: reference, calendar: calendar),
            !Task.isCancelled
        else { return }
        memories = built
        builtRequest = request
        browser.reconcile(with: built)
        // An open area shows every memory that arrives, so none of them counts as unopened.
        if isExpanded { markSeen() }
    }

    /// Records the shown memories as opened, so the calendar control loses its badge until more arrive.
    func markSeen() {
        guard let memories, !memories.isEmpty else { return }
        let record = OnThisDaySeenRecord(memories: memories)
        guard record != seenRecord else { return }
        seenRecord = record
        seenStore.save(record)
    }

    /// Another account or a sign-out: nothing of the previous library stays.
    func reset() {
        memories = nil
        builtRequest = nil
        browser = OnThisDayBrowser()
        isExpanded = false
        seenRecord = seenStore.load()
    }
}

/// The expandable memories area below the library's top controls: one stack of cards per earlier year.
struct MobileOnThisDayArea: View {
    let availability: OnThisDayAvailability
    @Binding var browser: OnThisDayBrowser
    let thumbnailFeed: UIKitThumbnailFeed?
    let onOpen: (OnThisDayYear) -> Void
    let onShowInLibrary: (PhotoItem) -> Void

    var body: some View {
        Group {
            switch availability {
            case .loading:
                status(L10n.string("memories.loading")) { ProgressView() }
            case .unavailable:
                status(L10n.string("memories.unavailable")) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            case .empty:
                status(L10n.string("memories.empty")) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                }
            case .partial(let memories):
                stacks(memories, mayGrow: true)
            case .ready(let memories):
                stacks(memories, mayGrow: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .background(ProtonColor.backgroundNorm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("memories.title"))
        .accessibilityIdentifier("library.memories")
    }

    private func status<Icon: View>(_ text: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.memories.status")
    }

    private func stacks(_ memories: OnThisDayMemories, mayGrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Years scroll sideways; cards of one year change only with the stack's own controls, so the two never
            // compete for the same gesture or move the library below.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(memories.years) { year in
                        MobileOnThisDayStack(
                            year: year,
                            browser: $browser,
                            thumbnailFeed: thumbnailFeed,
                            onOpen: onOpen,
                            onShowInLibrary: onShowInLibrary
                        )
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            if mayGrow {
                Text(L10n.string("memories.more_loading"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// One year: offset cards with the current photo on top, its position, and explicit browse and reveal controls.
private struct MobileOnThisDayStack: View {
    let year: OnThisDayYear
    @Binding var browser: OnThisDayBrowser
    let thumbnailFeed: UIKitThumbnailFeed?
    let onOpen: (OnThisDayYear) -> Void
    let onShowInLibrary: (PhotoItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var scaledCardSize: CGFloat = 148
    /// Large text sizes grow the cards up to a bound, so the area never pushes the library off a phone screen.
    private var cardSize: CGFloat { min(scaledCardSize, 220) }

    var body: some View {
        let index = browser.currentIndex(in: year)
        let current = year.items[index]
        let position = L10n.string("memories.position \(index + 1) \(year.items.count)")
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("memories.years_ago \(year.yearsAgo)"))
                    .font(.headline)
                Text(year.day.start.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Button {
                browser.select(index: index, in: year)
                onOpen(year)
            } label: {
                cards(index: index, current: current)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                [current.isVideo ? L10n.string("memories.kind_video") : L10n.string("memories.kind_photo"), position]
                    .joined(separator: ", "))
            .accessibilityHint(L10n.string("memories.open_hint"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(by: 1)
                case .decrement: move(by: -1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: L10n.string("memories.show_in_library")) { onShowInLibrary(current) }
            .accessibilityIdentifier("library.memories.card.\(year.yearsAgo)")

            HStack(spacing: 2) {
                Button {
                    move(by: -1)
                } label: {
                    Image(systemName: "chevron.backward")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(index == 0)
                .accessibilityLabel(L10n.string("memories.previous"))
                .accessibilityIdentifier("library.memories.previous.\(year.yearsAgo)")

                Text(position)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("library.memories.position.\(year.yearsAgo)")

                Button {
                    move(by: 1)
                } label: {
                    Image(systemName: "chevron.forward")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(index == year.items.count - 1)
                .accessibilityLabel(L10n.string("memories.next"))
                .accessibilityIdentifier("library.memories.next.\(year.yearsAgo)")

                Spacer(minLength: 4)

                Button {
                    onShowInLibrary(current)
                } label: {
                    Image(systemName: "square.grid.3x3")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .accessibilityLabel(L10n.string("memories.show_in_library"))
                .help(L10n.string("memories.show_in_library"))
                .accessibilityIdentifier("library.memories.showInLibrary.\(year.yearsAgo)")
            }
            .buttonStyle(.borderless)
            .frame(width: cardSize)
        }
        .frame(width: cardSize + 12, alignment: .leading)
    }

    /// Up to two following photos peek out behind the current one, so the stack shows that there is more to browse.
    private func cards(index: Int, current: PhotoItem) -> some View {
        let following = Array(year.items.dropFirst(index + 1).prefix(2))
        return ZStack {
            ForEach(Array(following.enumerated()).reversed(), id: \.element.uid) { depth, item in
                MobileSearchThumbnail(
                    uid: item.uid, size: cardSize, cornerRadius: 14, placeholderSymbol: "photo",
                    thumbnailFeed: thumbnailFeed
                )
                .rotationEffect(.degrees(depth == 0 ? 4 : -3))
                .offset(x: CGFloat(depth + 1) * 5, y: CGFloat(depth + 1) * -4)
            }
            MobileSearchThumbnail(
                uid: current.uid, size: cardSize, cornerRadius: 14, placeholderSymbol: "photo",
                failureSymbol: "exclamationmark.triangle", thumbnailFeed: thumbnailFeed
            )
            .overlay(alignment: .bottomLeading) {
                if current.isVideo { videoBadge(current) }
            }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .id(current.uid)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.push(from: .trailing))
        }
        .frame(width: cardSize, height: cardSize)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: current.uid)
    }

    private func videoBadge(_ item: PhotoItem) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
            if let seconds = item.durationSeconds, seconds.isFinite, seconds >= 0 {
                Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: .capsule)
        .padding(6)
        .accessibilityHidden(true)
    }

    private func move(by offset: Int) {
        browser.move(in: year, by: offset)
    }
}
