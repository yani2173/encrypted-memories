import PhotosCore
import XCTest

@testable import PhotoViewerCore

@MainActor
final class FilmstripThumbnailLoaderTests: XCTestCase {
    private let a = PhotoUID(volumeID: "v", nodeID: "a")
    private let b = PhotoUID(volumeID: "v", nodeID: "b")

    /// A source that records its reads and answers an image load only when the test lets it.
    @MainActor
    private final class Fixture {
        var shown: [String?] = []
        var memory: [PhotoUID: String] = [:]
        var selects: [PhotoUID?] = []
        var loads: [PhotoUID] = []
        var pending: [CheckedContinuation<String?, Never>] = []

        lazy var loader = FilmstripThumbnailLoader<String> { [unowned self] in self.shown.append($0) }

        var lastShown: String? { shown.last ?? nil }

        func answerNextLoad(with image: String?) {
            pending.removeFirst().resume(returning: image)
        }

        func load(_ uid: PhotoUID) async -> String? {
            loads.append(uid)
            return await withCheckedContinuation { pending.append($0) }
        }

        var librarySource: FilmstripThumbnailLoader<String>.Source {
            .library(
                memoryImage: { [unowned self] in self.memory[$0] },
                image: { [unowned self] in await self.load($0) })
        }

        var duplicatesSource: FilmstripThumbnailLoader<String>.Source {
            .duplicatesCopy(
                FilmstripVisibleReads(
                    select: { [unowned self] in self.selects.append($0) },
                    memoryImage: { [unowned self] in self.memory[$0] },
                    image: { [unowned self] in await self.load($0) }))
        }

        /// Lets every load that still waits end, so no test leaves a task behind.
        func releaseAll() {
            while !pending.isEmpty { answerNextLoad(with: nil) }
        }

        func settle() async {
            for _ in 0..<20 { await Task.yield() }
        }
    }

    func testALibraryPhotoWithAMemoryImageShowsItAtOnceAndLoadsNothing() async {
        let f = Fixture()
        f.memory[a] = "memory-a"

        f.loader.configure(uid: a, source: f.librarySource)
        await f.settle()

        XCTAssertEqual(f.lastShown, "memory-a")
        XCTAssertEqual(f.loads, [])
        XCTAssertEqual(f.loader.uid, a)
    }

    func testALibraryPhotoWithoutAMemoryImageLoadsAndShowsTheResult() async {
        let f = Fixture()

        f.loader.configure(uid: a, source: f.librarySource)
        await f.settle()
        XCTAssertEqual(f.loads, [a])
        XCTAssertNil(f.lastShown)

        f.answerNextLoad(with: "loaded-a")
        await f.settle()
        XCTAssertEqual(f.lastShown, "loaded-a")
    }

    func testALibraryPhotoWithoutAFeedLoadsNothing() async {
        let f = Fixture()

        f.loader.configure(uid: a, source: .library(memoryImage: { _ in nil }, image: nil))
        await f.settle()

        XCTAssertEqual(f.shown.count, 1)
        XCTAssertNil(f.lastShown)
    }

    func testAResultForAPhotoThatLeftTheCellIsDropped() async {
        let f = Fixture()
        f.loader.configure(uid: a, source: f.librarySource)
        await f.settle()

        f.loader.configure(uid: b, source: f.librarySource)
        await f.settle()
        f.answerNextLoad(with: "loaded-a")
        f.answerNextLoad(with: "loaded-b")
        await f.settle()

        XCTAssertEqual(f.lastShown, "loaded-b")
        XCTAssertFalse(f.shown.contains("loaded-a"))
    }

    func testADuplicatesCopyReadsNothingUntilItsCellIsOnScreen() async {
        let f = Fixture()
        f.memory[a] = "memory-a"

        f.loader.configure(uid: a, source: f.duplicatesSource)
        await f.settle()

        XCTAssertEqual(f.selects.count, 0, "the access opens when the cell appears")
        XCTAssertEqual(f.loads, [])
        XCTAssertNil(f.lastShown)
    }

    func testADuplicatesCopyOnScreenOpensItsAccessAndShowsTheMemoryImage() async {
        let f = Fixture()
        f.memory[a] = "memory-a"
        f.loader.configure(uid: a, source: f.duplicatesSource)

        f.loader.loadVisible()
        await f.settle()

        XCTAssertEqual(f.selects, [a])
        XCTAssertEqual(f.lastShown, "memory-a")
        XCTAssertEqual(f.loads, [])
    }

    func testADuplicatesCopyOnScreenLoadsItsThumbnail() async {
        let f = Fixture()
        f.loader.configure(uid: a, source: f.duplicatesSource)

        f.loader.loadVisible()
        await f.settle()
        XCTAssertEqual(f.loads, [a])
        f.answerNextLoad(with: "visible-a")
        await f.settle()

        XCTAssertEqual(f.lastShown, "visible-a")
    }

    func testLeavingTheScreenRevokesTheAccessAndDropsALateResult() async {
        let f = Fixture()
        f.loader.configure(uid: a, source: f.duplicatesSource)
        f.loader.loadVisible()
        await f.settle()

        f.loader.endVisible()
        f.answerNextLoad(with: "late-a")
        await f.settle()

        XCTAssertEqual(f.selects, [a, nil], "the access ends once")
        XCTAssertNil(f.lastShown)
        XCTAssertFalse(f.shown.contains("late-a"))
    }

    func testLeavingTheScreenRemovesTheShownThumbnailOfACopy() async {
        let f = Fixture()
        f.memory[a] = "memory-a"
        f.loader.configure(uid: a, source: f.duplicatesSource)
        f.loader.loadVisible()
        XCTAssertEqual(f.lastShown, "memory-a", "the copy shows its thumbnail while it is on screen")

        f.loader.endVisible()

        XCTAssertNil(f.lastShown, "no thumbnail of a copy stays after it left the screen")
    }

    func testALibraryPhotoNeverRevokesAnything() async {
        let f = Fixture()
        f.loader.configure(uid: a, source: f.librarySource)

        f.loader.loadVisible()
        f.loader.endVisible()
        await f.settle()

        XCTAssertEqual(f.selects, [])
        XCTAssertEqual(f.loads, [a], "only the library load of configure ran")
        f.releaseAll()
    }

    func testLeavingTheScreenKeepsTheThumbnailOfALibraryPhoto() async {
        let f = Fixture()
        f.memory[a] = "memory-a"
        f.loader.configure(uid: a, source: f.librarySource)

        f.loader.loadVisible()
        f.loader.endVisible()
        await f.settle()

        XCTAssertEqual(f.lastShown, "memory-a")
        XCTAssertEqual(f.selects, [])
    }

    func testReconfiguringRevokesTheAccessOfTheEarlierCopy() async {
        let f = Fixture()
        f.loader.configure(uid: a, source: f.duplicatesSource)
        f.loader.loadVisible()
        await f.settle()

        f.loader.configure(uid: b, source: f.librarySource)
        f.loader.loadVisible()
        await f.settle()

        XCTAssertEqual(f.selects, [a, nil], "a library photo that follows a copy opens no access")
        f.releaseAll()
    }

    func testConfiguringACopyRemovesTheImageOfTheLibraryPhotoThatTheCellShowed() async {
        let f = Fixture()
        f.memory[a] = "memory-a"
        f.loader.configure(uid: a, source: f.librarySource)
        XCTAssertEqual(f.lastShown, "memory-a")

        f.loader.configure(uid: b, source: f.duplicatesSource)

        XCTAssertNil(f.lastShown, "a copy shows nothing until its cell is on screen")
    }

    func testCancelRevokesTheAccessAndDropsTheResult() async {
        let f = Fixture()
        f.loader.configure(uid: a, source: f.duplicatesSource)
        f.loader.loadVisible()
        await f.settle()

        f.loader.cancel()
        f.answerNextLoad(with: "late-a")
        await f.settle()

        XCTAssertEqual(f.selects, [a, nil])
        XCTAssertFalse(f.shown.contains("late-a"))
    }

    func testResetEndsTheAccessClearsTheCellAndForgetsThePhoto() async {
        let f = Fixture()
        f.memory[a] = "memory-a"
        f.loader.configure(uid: a, source: f.duplicatesSource)
        f.loader.loadVisible()
        await f.settle()
        XCTAssertEqual(f.lastShown, "memory-a")

        f.loader.reset()

        XCTAssertEqual(f.selects, [a, nil])
        XCTAssertNil(f.lastShown)
        XCTAssertNil(f.loader.uid)
        f.loader.loadVisible()
        XCTAssertEqual(f.selects, [a, nil], "a reset cell opens no access")
    }
}
