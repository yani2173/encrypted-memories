import PhotosCore

/// The reads of a Duplicates copy while its filmstrip cell is on screen.
public struct FilmstripVisibleReads<Image> {
    /// Opens the read access of a photo, or ends the open one when `nil`.
    public let select: (PhotoUID?) -> Void
    public let memoryImage: (PhotoUID) -> Image?
    public let image: (PhotoUID) async -> Image?

    public init(
        select: @escaping (PhotoUID?) -> Void,
        memoryImage: @escaping (PhotoUID) -> Image?,
        image: @escaping (PhotoUID) async -> Image?
    ) {
        self.select = select
        self.memoryImage = memoryImage
        self.image = image
    }
}

/// The thumbnail load of one filmstrip cell, shared by the Mac and the iPhone filmstrip.
///
/// A library photo reads its thumbnail at once. A Duplicates copy may lie outside the library, so it reads only while
/// its cell is on screen: `loadVisible` opens the read access, and `endVisible`, `cancel` and `reset` revoke it.
/// A result that arrives after the cell shows another photo, or after any cancel, is dropped.
@MainActor
public final class FilmstripThumbnailLoader<Image> {
    public enum Source {
        /// A photo of the library. `image` is `nil` while no feed is available.
        case library(memoryImage: (PhotoUID) -> Image?, image: ((PhotoUID) async -> Image?)?)
        /// A Duplicates copy. `reads` is `nil` while no feed is available.
        case duplicatesCopy(FilmstripVisibleReads<Image>?)
    }

    private let show: (Image?) -> Void
    private var representedUID: PhotoUID?
    private var task: Task<Void, Never>?
    private var visibleReads: FilmstripVisibleReads<Image>?
    private var generation: UInt64 = 0

    /// `show` puts the thumbnail, or nothing, into the cell.
    public init(show: @escaping (Image?) -> Void) {
        self.show = show
    }

    // A released cell must not leave its load running; cancelling it ends a Duplicates read access.
    deinit { task?.cancel() }

    public var uid: PhotoUID? { representedUID }

    /// Points the loader at `uid` and starts what the source allows now.
    public func configure(uid: PhotoUID, source: Source) {
        cancel()
        representedUID = uid
        switch source {
        case .duplicatesCopy(let reads):
            visibleReads = reads
            show(nil)
        case .library(let memoryImage, let image):
            visibleReads = nil
            let memory = memoryImage(uid)
            show(memory)
            guard memory == nil, let image else { return }
            start(uid: uid, load: image)
        }
    }

    /// Opens the read access of a Duplicates copy that came on screen and loads its thumbnail.
    public func loadVisible() {
        guard let visibleReads, let uid = representedUID else { return }
        task?.cancel()
        generation &+= 1
        visibleReads.select(uid)
        let memory = visibleReads.memoryImage(uid)
        show(memory)
        guard memory == nil else { return }
        start(uid: uid, load: visibleReads.image)
    }

    /// Revokes the read access of a Duplicates copy that left the screen.
    public func endVisible() {
        guard visibleReads != nil else { return }
        cancel()
        show(nil)
    }

    public func cancel() {
        visibleReads?.select(nil)
        task?.cancel()
        task = nil
        generation &+= 1
    }

    /// Prepares a reused cell: no load, no photo.
    public func reset() {
        cancel()
        representedUID = nil
        show(nil)
    }

    private func start(uid: PhotoUID, load: @escaping (PhotoUID) async -> Image?) {
        let requestGeneration = generation
        task = Task { [weak self] in
            let image = await load(uid)
            guard !Task.isCancelled, let self, self.representedUID == uid, self.generation == requestGeneration
            else { return }
            self.show(image)
        }
    }
}
