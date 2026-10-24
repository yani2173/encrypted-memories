import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit

/// A bounded, reusable all-media strip for the mobile viewer.
///
/// The viewer's page index remains the navigation owner. This adapter only presents the supplied route order
/// and reports the selected item's full UID back to that owner.
struct MobileViewerFilmstrip: UIViewRepresentable {
    let items: [PhotoItem]
    let selectedUID: PhotoUID?
    let feed: UIKitThumbnailFeed?
    let itemSide: CGFloat
    /// The route strip separates its photos; a series strip sets them edge to edge like the Photos app.
    var itemSpacing: CGFloat = 8
    /// The Duplicates viewer shows copies that can lie outside the library; each one reads only while on screen.
    var allowsVisibleDuplicateThumbnails = false
    let onSelect: (PhotoUID) -> Void

    private static let minimumInteractionSide: CGFloat = 44

    func makeCoordinator() -> Coordinator {
        Coordinator(
            items: items, selectedUID: selectedUID, feed: feed,
            allowsVisibleDuplicateThumbnails: allowsVisibleDuplicateThumbnails, onSelect: onSelect)
    }

    @MainActor
    func makeUIView(context: Context) -> MobileViewerFilmstripCollectionView {
        let layout = MobileViewerFilmstripFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: itemSide, height: itemSide)
        layout.minimumLineSpacing = itemSpacing
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        let collectionView = MobileViewerFilmstripCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceHorizontal = true
        collectionView.alwaysBounceVertical = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.decelerationRate = .fast
        collectionView.accessibilityLabel = L10n.string("a11y.photo_library_grid")
        collectionView.register(
            MobileViewerFilmstripCell.self,
            forCellWithReuseIdentifier: MobileViewerFilmstripCell.reuseIdentifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.onLayout = { [weak coordinator = context.coordinator] collectionView in
            coordinator?.layoutDidChange(collectionView)
        }
        context.coordinator.attach(to: collectionView)
        return collectionView
    }

    @MainActor
    func updateUIView(_ collectionView: MobileViewerFilmstripCollectionView, context: Context) {
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let newSize = CGSize(width: itemSide, height: itemSide)
            if layout.itemSize != newSize {
                layout.itemSize = newSize
                layout.invalidateLayout()
            }
        }
        context.coordinator.update(
            collectionView: collectionView,
            items: items,
            selectedUID: selectedUID,
            feed: feed,
            onSelect: onSelect
        )
    }

    @MainActor
    static func dismantleUIView(_ collectionView: MobileViewerFilmstripCollectionView, coordinator: Coordinator) {
        coordinator.dismantle(collectionView)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private var items: [PhotoItem]
        private var selectedUID: PhotoUID?
        private var feed: UIKitThumbnailFeed?
        private let allowsVisibleDuplicateThumbnails: Bool
        private var onSelect: (PhotoUID) -> Void
        private weak var collectionView: MobileViewerFilmstripCollectionView?
        private var lastLayoutSize: CGSize = .zero
        private var centerScheduled = false

        init(
            items: [PhotoItem],
            selectedUID: PhotoUID?,
            feed: UIKitThumbnailFeed?,
            allowsVisibleDuplicateThumbnails: Bool,
            onSelect: @escaping (PhotoUID) -> Void
        ) {
            self.items = items
            self.selectedUID = selectedUID
            self.feed = feed
            self.allowsVisibleDuplicateThumbnails = allowsVisibleDuplicateThumbnails
            self.onSelect = onSelect
        }

        func attach(to collectionView: MobileViewerFilmstripCollectionView) {
            self.collectionView = collectionView
            collectionView.reloadData()
            scheduleCentering(in: collectionView, animated: false)
        }

        func update(
            collectionView: MobileViewerFilmstripCollectionView,
            items: [PhotoItem],
            selectedUID: PhotoUID?,
            feed: UIKitThumbnailFeed?,
            onSelect: @escaping (PhotoUID) -> Void
        ) {
            let oldSelectedUID = self.selectedUID
            let feedChanged = !sameFeed(feed, self.feed)
            let update = BurstFilmstripUpdatePolicy.resolve(
                previousItems: self.items.map(\.uid),
                currentItems: items.map(\.uid),
                previousSelectedUID: oldSelectedUID,
                currentSelectedUID: selectedUID
            )

            self.items = items
            self.selectedUID = selectedUID
            self.feed = feed
            self.onSelect = onSelect

            if update.reloadData || feedChanged {
                collectionView.reloadData()
                scheduleCentering(in: collectionView, animated: false)
            } else if update.selectCurrent {
                reloadSelectionCells(in: collectionView, oldUID: oldSelectedUID, newUID: selectedUID)
                scheduleCentering(in: collectionView, animated: true)
            }
        }

        func layoutDidChange(_ collectionView: MobileViewerFilmstripCollectionView) {
            let size = collectionView.bounds.size
            updateEdgeInsets(in: collectionView)
            guard size != lastLayoutSize else { return }
            lastLayoutSize = size
            scheduleCentering(in: collectionView, animated: false)
        }

        func dismantle(_ collectionView: MobileViewerFilmstripCollectionView) {
            centerScheduled = false
            collectionView.onLayout = nil
            for cell in collectionView.visibleCells {
                (cell as? MobileViewerFilmstripCell)?.cancelThumbnailLoad()
            }
            self.collectionView = nil
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MobileViewerFilmstripCell.reuseIdentifier,
                for: indexPath
            )
            guard let filmstripCell = cell as? MobileViewerFilmstripCell,
                items.indices.contains(indexPath.item)
            else {
                return cell
            }
            let item = items[indexPath.item]
            filmstripCell.configure(
                item: item,
                selected: item.uid == selectedUID,
                position: indexPath.item + 1,
                total: items.count,
                feed: feed,
                allowsVisibleDuplicateThumbnails: allowsVisibleDuplicateThumbnails
            )
            return filmstripCell
        }

        func collectionView(
            _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
        ) {
            (cell as? MobileViewerFilmstripCell)?.loadVisibleThumbnail()
        }

        func collectionView(
            _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            // A late callback can arrive for a reused cell that already shows its next photo.
            guard !collectionView.visibleCells.contains(cell) else { return }
            (cell as? MobileViewerFilmstripCell)?.endVisibleThumbnail()
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard items.indices.contains(indexPath.item) else { return }
            let item = items[indexPath.item]
            guard item.uid != selectedUID else {
                scheduleCentering(in: collectionView, animated: true)
                return
            }
            onSelect(item.uid)
        }

        private func reloadSelectionCells(
            in collectionView: UICollectionView,
            oldUID: PhotoUID?,
            newUID: PhotoUID?
        ) {
            var paths = Set<IndexPath>()
            if let oldUID, let index = items.firstIndex(where: { $0.uid == oldUID }) {
                paths.insert(IndexPath(item: index, section: 0))
            }
            if let newUID, let index = items.firstIndex(where: { $0.uid == newUID }) {
                paths.insert(IndexPath(item: index, section: 0))
            }
            let validPaths = paths.filter { collectionView.indexPathsForVisibleItems.contains($0) }
            guard !validPaths.isEmpty else { return }
            collectionView.reloadItems(at: Array(validPaths))
        }

        private func updateEdgeInsets(in collectionView: UICollectionView) {
            guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
            let side = max(MobileViewerFilmstrip.minimumInteractionSide, layout.itemSize.width)
            let inset = max(0, (collectionView.bounds.width - side) / 2)
            let next = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            guard layout.sectionInset != next else { return }
            layout.sectionInset = next
            layout.invalidateLayout()
        }

        private func scheduleCentering(in collectionView: UICollectionView, animated: Bool) {
            guard selectedUID != nil, !items.isEmpty, !centerScheduled else { return }
            centerScheduled = true
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                self.centerScheduled = false
                self.centerSelected(in: collectionView, animated: animated)
            }
        }

        private func centerSelected(in collectionView: UICollectionView, animated: Bool) {
            guard let selectedUID,
                let index = items.firstIndex(where: { $0.uid == selectedUID }),
                items.indices.contains(index)
            else { return }
            updateEdgeInsets(in: collectionView)
            collectionView.layoutIfNeeded()
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: animated)
        }

        private func sameFeed(_ lhs: UIKitThumbnailFeed?, _ rhs: UIKitThumbnailFeed?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case (let lhs?, let rhs?):
                return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
            default:
                return false
            }
        }
    }
}

/// Loads one thumbnail for a view that is on screen, and keeps trying until the image exists.
///
/// A single feed request can return no image: series members are not library items, so their bytes may still
/// be on the way when the cell appears. The shared feed core asks with visible priority and waits for its arrival
/// wake or a bounded backoff (`ThumbnailFeedCore.visibleDecoded`). Cancelling the task ends it.
enum MobileThumbnailArrival {
    static func image(for uid: PhotoUID, feed: UIKitThumbnailFeed) async -> UIImage? {
        guard await feed.feedCore.visibleDecoded(for: uid) != nil, !Task.isCancelled else { return nil }
        return await feed.image(for: uid)
    }
}

@MainActor
final class MobileViewerFilmstripCollectionView: UICollectionView {
    var onLayout: ((MobileViewerFilmstripCollectionView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

private final class MobileViewerFilmstripFlowLayout: UICollectionViewFlowLayout {}

@MainActor
private final class MobileViewerFilmstripCell: UICollectionViewCell {
    static let reuseIdentifier = "MobileViewerFilmstripCell"

    private let imageView = UIImageView()
    private var representedUID: PhotoUID?
    private var thumbnailTask: Task<Void, Never>?
    private var visibleThumbnail: VisibleThumbnailSession?
    private var generation: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = false
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = [.button, .image]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // A released cell must not leave its load running; cancelling it ends a Duplicates read access.
    deinit { thumbnailTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(10, max(7, bounds.width * 0.14))
        contentView.layer.cornerRadius = radius
        imageView.layer.cornerRadius = radius
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailLoad()
        representedUID = nil
        imageView.image = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityTraits = [.button, .image]
    }

    func configure(
        item: PhotoItem,
        selected: Bool,
        position: Int,
        total: Int,
        feed: UIKitThumbnailFeed?,
        allowsVisibleDuplicateThumbnails: Bool
    ) {
        cancelThumbnailLoad()
        generation &+= 1
        let requestGeneration = generation
        representedUID = item.uid
        updateSelection(selected)
        updateAccessibility(item: item, selected: selected, position: position, total: total)
        // A Duplicates copy reads only while the cell is on screen (`loadVisibleThumbnail`).
        guard !allowsVisibleDuplicateThumbnails else {
            visibleThumbnail = feed.map { VisibleThumbnailSession(feed: $0.feedCore) }
            imageView.image = nil
            return
        }
        visibleThumbnail = nil
        imageView.image = feed?.memoryImage(for: item.uid)

        guard imageView.image == nil, let feed else { return }
        let uid = item.uid
        thumbnailTask = Task { [weak self, feed] in
            let image = await MobileThumbnailArrival.image(for: uid, feed: feed)
            guard !Task.isCancelled else { return }
            guard let self,
                self.representedUID == uid,
                self.generation == requestGeneration
            else { return }
            self.imageView.image = image
        }
    }

    func loadVisibleThumbnail() {
        guard let visibleThumbnail, let uid = representedUID else { return }
        thumbnailTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        visibleThumbnail.select(uid)
        imageView.image = visibleThumbnail.memoryImage(for: uid)
        guard imageView.image == nil else { return }
        thumbnailTask = Task { [weak self] in
            let image = await visibleThumbnail.visibleImage(for: uid)
            guard !Task.isCancelled, let self, self.representedUID == uid, self.generation == requestGeneration
            else { return }
            self.imageView.image = image
        }
    }

    /// Revokes the read access of a Duplicates copy that left the screen.
    func endVisibleThumbnail() {
        guard visibleThumbnail != nil else { return }
        cancelThumbnailLoad()
        imageView.image = nil
    }

    func cancelThumbnailLoad() {
        visibleThumbnail?.end()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        generation &+= 1
    }

    private func updateSelection(_ selected: Bool) {
        contentView.layer.borderWidth = selected ? 2 : 0
        contentView.layer.borderColor = UIColor.white.cgColor
        accessibilityTraits = selected ? [.button, .image, .selected] : [.button, .image]
    }

    private func updateAccessibility(item: PhotoItem, selected: Bool, position: Int, total: Int) {
        let kind = L10n.string(item.isVideo ? "a11y.video" : "a11y.photo")
        accessibilityLabel = kind
        accessibilityValue = L10n.string("a11y.grid.position \(position) \(total)")
        accessibilityHint = L10n.string("a11y.open_photo_hint")
        updateSelection(selected)
    }
}
