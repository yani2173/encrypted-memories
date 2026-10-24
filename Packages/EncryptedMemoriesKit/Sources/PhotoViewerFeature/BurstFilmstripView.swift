import AppKit
import MediaCache
import MediaFeedCore
import PhotoViewerCore
import PhotosCore
import SwiftUI

/// macOS-native filmstrip for Proton burst/series members.
///
/// The data model is platform-neutral (`PhotoItem` + `BurstGroupProvider`); this file is only the macOS
/// presentation. Other platforms can keep the same viewer model and replace this collection view with a
/// native iOS/iPadOS carousel.
struct BurstFilmstripView: NSViewRepresentable {
    let items: [PhotoItem]
    let selectedUID: PhotoUID?
    let feed: ThumbnailFeed
    let itemSide: CGFloat
    let showsHorizontalScroller: Bool
    var allowsVisibleDuplicateThumbnails = false
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            feed: feed, itemSide: itemSide, showsHorizontalScroller: showsHorizontalScroller,
            allowsVisibleDuplicateThumbnails: allowsVisibleDuplicateThumbnails, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: itemSide, height: itemSide)
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        let collectionView = NSCollectionView()
        collectionView.frame = NSRect(x: 0, y: 0, width: 1, height: itemSide)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = []
        collectionView.wantsLayer = true
        collectionView.layer?.backgroundColor = NSColor.clear.cgColor
        collectionView.register(BurstThumbnailItem.self, forItemWithIdentifier: BurstThumbnailItem.reuseID)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = showsHorizontalScroller
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.documentView = collectionView

        context.coordinator.collectionView = collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let previousItems = context.coordinator.items.map(\.uid)
        let update = BurstFilmstripUpdatePolicy.resolve(
            previousItems: previousItems,
            currentItems: items.map(\.uid),
            previousSelectedUID: context.coordinator.selectedUID,
            currentSelectedUID: selectedUID,
            previousItemSide: context.coordinator.appliedItemSide.map { Double($0) },
            currentItemSide: Double(itemSide),
            previousShowsScroller: context.coordinator.appliedShowsHorizontalScroller,
            currentShowsScroller: showsHorizontalScroller
        )
        context.coordinator.items = items
        context.coordinator.selectedUID = selectedUID
        context.coordinator.itemSide = itemSide
        context.coordinator.showsHorizontalScroller = showsHorizontalScroller
        context.coordinator.onSelect = onSelect
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = showsHorizontalScroller
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        guard let collectionView = scrollView.documentView as? NSCollectionView else { return }
        if update.updateLayout, let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = NSSize(width: itemSide, height: itemSide)
            layout.invalidateLayout()
        }
        collectionView.layer?.backgroundColor = NSColor.clear.cgColor
        if update.reloadData { collectionView.reloadData() }
        if update.selectCurrent {
            context.coordinator.refreshSelectionAppearance()
            context.coordinator.selectCurrent()
        }
        context.coordinator.appliedItemSide = itemSide
        context.coordinator.appliedShowsHorizontalScroller = showsHorizontalScroller
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        for item in coordinator.collectionView?.visibleItems() ?? [] {
            (item as? BurstThumbnailItem)?.cancelThumbnailLoad()
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var items: [PhotoItem] = []
        var selectedUID: PhotoUID?
        let feed: ThumbnailFeed
        let allowsVisibleDuplicateThumbnails: Bool
        var itemSide: CGFloat
        var showsHorizontalScroller: Bool
        var onSelect: (Int) -> Void
        weak var collectionView: NSCollectionView?
        var appliedItemSide: CGFloat?
        var appliedShowsHorizontalScroller: Bool?

        init(
            feed: ThumbnailFeed, itemSide: CGFloat, showsHorizontalScroller: Bool,
            allowsVisibleDuplicateThumbnails: Bool, onSelect: @escaping (Int) -> Void
        ) {
            self.feed = feed
            self.allowsVisibleDuplicateThumbnails = allowsVisibleDuplicateThumbnails
            self.itemSide = itemSide
            self.showsHorizontalScroller = showsHorizontalScroller
            self.onSelect = onSelect
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: BurstThumbnailItem.reuseID, for: indexPath)
            guard let thumbnail = item as? BurstThumbnailItem, items.indices.contains(indexPath.item) else {
                return item
            }
            let photo = items[indexPath.item]
            thumbnail.configure(
                photo: photo, selected: photo.uid == selectedUID, itemSide: itemSide, feed: feed,
                allowsVisibleDuplicateThumbnails: allowsVisibleDuplicateThumbnails)
            return thumbnail
        }

        func collectionView(
            _ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            (item as? BurstThumbnailItem)?.loadVisibleThumbnail()
        }

        func collectionView(
            _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            // A late callback can arrive for a reused item that already shows its next photo.
            guard !collectionView.visibleItems().contains(item) else { return }
            (item as? BurstThumbnailItem)?.endVisibleThumbnail()
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let index = indexPaths.first?.item, items.indices.contains(index) else { return }
            onSelect(index)
        }

        @MainActor func selectCurrent() {
            guard let collectionView, let selectedUID,
                let index = items.firstIndex(where: { $0.uid == selectedUID })
            else { return }
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.deselectAll(nil)
            collectionView.selectItems(at: [indexPath], scrollPosition: [.centeredHorizontally])
            collectionView.scrollToItems(at: [indexPath], scrollPosition: [.centeredHorizontally])
        }

        @MainActor func refreshSelectionAppearance() {
            for item in collectionView?.visibleItems() ?? [] {
                guard let thumbnail = item as? BurstThumbnailItem else { continue }
                thumbnail.setSelected(thumbnail.uid == selectedUID)
            }
        }
    }
}

private final class BurstThumbnailItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("BurstThumbnailItem")

    private var loadTask: Task<Void, Never>?
    private var representedUID: PhotoUID?
    private var visibleThumbnail: VisibleThumbnailSession?

    // A released item must not leave its load running; cancelling it ends a Duplicates read access.
    deinit { loadTask?.cancel() }

    override func loadView() {
        view = BurstThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailLoad()
        representedUID = nil
        cellView?.image = nil
        cellView?.selected = false
    }

    func configure(
        photo: PhotoItem, selected: Bool, itemSide: CGFloat, feed: ThumbnailFeed, allowsVisibleDuplicateThumbnails: Bool
    ) {
        cancelThumbnailLoad()
        representedUID = photo.uid
        view.frame.size = NSSize(width: itemSide, height: itemSide)
        cellView?.selected = selected
        // A Duplicates copy may lie outside the library, so it reads only while on screen (`loadVisibleThumbnail`).
        guard !allowsVisibleDuplicateThumbnails else {
            visibleThumbnail = VisibleThumbnailSession(feed: feed.feedCore)
            cellView?.image = nil
            return
        }
        visibleThumbnail = nil
        cellView?.image = feed.memoryImage(for: photo.uid)
        guard cellView?.image == nil else { return }
        loadTask = Task {
            let image = await feed.image(for: photo.uid)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.representedUID == photo.uid else { return }
                self.cellView?.image = image
            }
        }
    }

    func loadVisibleThumbnail() {
        guard let visibleThumbnail, let uid = representedUID else { return }
        loadTask?.cancel()
        visibleThumbnail.select(uid)
        cellView?.image = visibleThumbnail.memoryImage(for: uid)
        guard cellView?.image == nil else { return }
        loadTask = Task { [weak self] in
            let image = await visibleThumbnail.visibleImage(for: uid)
            guard !Task.isCancelled, let self, self.representedUID == uid else { return }
            self.cellView?.image = image
        }
    }

    /// Revokes the read access of a Duplicates copy that left the screen.
    func endVisibleThumbnail() {
        guard visibleThumbnail != nil else { return }
        cancelThumbnailLoad()
        cellView?.image = nil
    }

    func cancelThumbnailLoad() {
        visibleThumbnail?.end()
        loadTask?.cancel()
        loadTask = nil
    }

    var uid: PhotoUID? { representedUID }

    func setSelected(_ selected: Bool) {
        cellView?.selected = selected
    }

    private var cellView: BurstThumbnailCellView? { view as? BurstThumbnailCellView }
}

private final class BurstThumbnailCellView: NSView {
    private let imageLayer = CALayer()

    var image: NSImage? {
        didSet {
            var rect = image.map { NSRect(origin: .zero, size: $0.size) } ?? .zero
            imageLayer.contents = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }

    var selected = false {
        didSet { updateSelectionRing() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.16).cgColor

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 10
        imageLayer.cornerCurve = .continuous
        layer?.addSublayer(imageLayer)
        updateSelectionRing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        let radius = min(14, max(8, bounds.width * 0.14))
        layer?.cornerRadius = radius
        imageLayer.cornerRadius = radius
        imageLayer.frame = bounds
    }

    private func updateSelectionRing() {
        layer?.borderWidth = selected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
