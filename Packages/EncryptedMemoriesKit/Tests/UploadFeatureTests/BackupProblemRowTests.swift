#if os(macOS)
    import AppKit
    import CoreGraphics
    import Observation
    import PhotosCore
    import SwiftUI
    import UploadCore
    import XCTest

    @testable import UploadFeature

    /// Problem-list rows without a Photos source reserve the same thumbnail square as rows with one, show the same
    /// gray placeholder, and ask for no picture. The rendering assertions run on macOS only: their harness draws
    /// through an AppKit window, while the row view itself is shared with iOS and iPadOS.
    @MainActor
    final class BackupProblemRowTests: XCTestCase {
        private static let renderedWidth = 320
        private static let renderedHeight = 80
        private static let photo = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "fixture-x")

        func testARowWithoutASourceShowsTheSamePlaceholderAsARowWhosePictureCannotLoad() async throws {
            let model = BackupProblemPreviewModel { _ in nil }
            model.open()
            defer { model.close() }
            let expected = try await Self.capture(
                Self.row(source: Self.photo, model: model)
            ).takeInk()

            for (name, source) in [
                ("no source", nil as UploadSourceIdentity?),
                ("a folder file", UploadSourceIdentity(kind: .fileURL, identifier: "fixture.jpg")),
                ("an empty identifier", UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "")),
            ] {
                let ink = try await Self.capture(Self.row(source: source, model: model)).takeInk()
                XCTAssertEqual(
                    ink, expected,
                    "a row with \(name) shows the placeholder of a row whose picture cannot load")
            }
        }

        func testARowWithoutAPreviewsModelReservesTheSquareAndShowsThePlaceholder() async throws {
            let previews = BackupProblemPreviewModel { _ in nil }
            previews.open()
            defer { previews.close() }
            let withoutModel = BackupProblemRow(item: Self.item(source: nil))
            let withSource = BackupProblemRow(item: Self.item(source: Self.photo), previews: previews)

            // A direct size guard: the row must fit the 40-point thumbnail square; its text alone is 35 tall.
            XCTAssertGreaterThanOrEqual(
                Self.fittedSize(of: withoutModel).height, 40,
                "a row without a previews model reserves the height of the thumbnail square")
            XCTAssertEqual(
                Self.fittedSize(of: withoutModel), Self.fittedSize(of: withSource),
                "a row without a previews model reserves the same thumbnail square")

            // A direct symbol guard: the leading 40 columns hold the photo symbol's ink, not only flat fill.
            let withoutModelPixels = try await Self.capture(withoutModel)
            let symbol = withoutModelPixels.inkCount(columns: 0..<40)
            XCTAssertGreaterThanOrEqual(symbol, 25, "the placeholder shows the photo symbol")
            XCTAssertLessThanOrEqual(symbol, 1_000, "the placeholder square is mostly flat fill")

            // The same guards for a row that has a source but no previews model.
            let withSourceWithoutModel = BackupProblemRow(item: Self.item(source: Self.photo))
            XCTAssertGreaterThanOrEqual(
                Self.fittedSize(of: withSourceWithoutModel).height, 40,
                "a row with a source but no previews model reserves the height of the thumbnail square")
            XCTAssertEqual(
                Self.fittedSize(of: withSourceWithoutModel), Self.fittedSize(of: withSource),
                "a row with a source but no previews model reserves the same thumbnail square")
            let withSourceWithoutModelPixels = try await Self.capture(withSourceWithoutModel)
            XCTAssertEqual(
                withSourceWithoutModelPixels.takeInk(), withoutModelPixels.takeInk(),
                "a row with a source but no previews model draws the placeholder of a row without a source")
        }

        func testMixedRowsLineUpAndARowWithoutASourceRequestsNoPicture() async throws {
            let loads = LoadLog()
            let previews = BackupProblemPreviewModel { _ in Self.magentaBitmap() }
            previews.open()
            defer { previews.close() }
            let sourceless = BackupProblemPreviewModel(load: loads.load)
            sourceless.open()
            defer { sourceless.close() }
            let withSource = BackupProblemRow(item: Self.item(source: Self.photo), previews: previews)
            let withoutSource = BackupProblemRow(item: Self.item(source: nil), previews: sourceless)

            // Fitted sizes are synchronous, so no window is needed to compare the reserved squares.
            XCTAssertEqual(
                Self.fittedSize(of: withoutSource), Self.fittedSize(of: withSource),
                "a row without a source reserves the same thumbnail square")

            let picture = try await Self.capture(withSource)
            let placeholder = try await Self.capture(withoutSource)
            XCTAssertTrue(loads.requested.isEmpty, "a row without a source requests no picture")
            let band = try XCTUnwrap(picture.magentaColumns())
            XCTAssertEqual(band.count, 40, "the row with a source keeps its thumbnail square")
            XCTAssertEqual(
                placeholder.takeInk(fromColumn: band.upperBound), picture.takeInk(fromColumn: band.upperBound),
                "the category symbol and the text of both rows start at the same edges")
        }

        func testAModelAddedToARowWithAStableUIDStartsTheThumbnailLoad() async throws {
            let loads = LoadLog()
            loads.image = Self.magentaBitmap()
            let box = PreviewModelBox()
            let renderer = LiveRowRenderer(view: BoxedProblemRow(item: Self.item(source: Self.photo), box: box))
            defer { renderer.close() }
            try await renderer.settle()
            XCTAssertTrue(loads.requested.isEmpty, "a row without a previews model requests no picture")
            XCTAssertNil(
                try renderer.snapshot().magentaColumns(), "a row without a previews model shows the placeholder")

            let previews = BackupProblemPreviewModel(load: loads.load)
            previews.open()
            defer { previews.close() }
            box.previews = previews
            try await renderer.settle()
            let uid = try XCTUnwrap(BackupProblemPreviewModel.uid(for: Self.photo))
            XCTAssertEqual(
                loads.requested, [uid.nodeID],
                "adding a previews model to a row with a stable uid starts the thumbnail load")
            XCTAssertNotNil(
                try renderer.snapshot().magentaColumns(), "the row with an added model shows its loaded picture")
        }

        func testAModelRemovedFromARowWithAStableUIDClearsTheLoadedImage() async throws {
            let loads = LoadLog()
            loads.image = Self.magentaBitmap()
            let previews = BackupProblemPreviewModel(load: loads.load)
            previews.open()
            defer { previews.close() }
            let box = PreviewModelBox(previews: previews)
            let renderer = LiveRowRenderer(view: BoxedProblemRow(item: Self.item(source: Self.photo), box: box))
            defer { renderer.close() }
            try await renderer.settle()
            XCTAssertNotNil(
                try renderer.snapshot().magentaColumns(), "the row with a model shows its loaded picture")

            box.previews = nil
            try await renderer.settle()
            XCTAssertNil(
                try renderer.snapshot().magentaColumns(), "removing the model clears the loaded picture")
            XCTAssertEqual(
                loads.requested.count, 1, "removing the model starts no second load")
        }

        func testReplacingTheModelLoadsThePictureForTheSameUID() async throws {
            let first = BackupProblemPreviewModel { _ in nil }
            first.open()
            defer { first.close() }
            let loads = LoadLog()
            loads.image = Self.magentaBitmap()
            let second = BackupProblemPreviewModel(load: loads.load)
            second.open()
            defer { second.close() }
            let box = PreviewModelBox(previews: first)
            let renderer = LiveRowRenderer(view: BoxedProblemRow(item: Self.item(source: Self.photo), box: box))
            defer { renderer.close() }
            try await renderer.settle()
            XCTAssertNil(try renderer.snapshot().magentaColumns())

            box.previews = second
            try await renderer.settle()
            XCTAssertEqual(loads.requested, [try XCTUnwrap(BackupProblemPreviewModel.uid(for: Self.photo)).nodeID])
            XCTAssertNotNil(
                try renderer.snapshot().magentaColumns(), "the new model's picture replaces the placeholder")
        }

        func testReplacingTheModelKeepsThePictureWhileTheNewLoadIsPending() async throws {
            let first = BackupProblemPreviewModel { _ in Self.magentaBitmap() }
            first.open()
            defer { first.close() }
            let held = HeldLoad()
            let second = BackupProblemPreviewModel(load: held.load)
            second.open()
            defer {
                held.finish()
                second.close()
            }
            let box = PreviewModelBox(previews: first)
            let renderer = LiveRowRenderer(view: BoxedProblemRow(item: Self.item(source: Self.photo), box: box))
            defer { renderer.close() }
            try await renderer.settle()
            XCTAssertNotNil(try renderer.snapshot().magentaColumns())
            box.previews = second
            try await renderer.settle()
            XCTAssertTrue(held.started, "the replacement model starts its load")
            XCTAssertNotNil(try renderer.snapshot().magentaColumns(), "the picture stays visible during the load")
            held.finish()
            try await renderer.settle()
            let replacement = try renderer.snapshot()
            XCTAssertNil(replacement.magentaColumns(), "the old picture is replaced")
            XCTAssertNotNil(replacement.cyanColumns(), "the new picture is visible")
        }

        // MARK: - Building

        private static func item(source: UploadSourceIdentity?) -> BackupFailedItem {
            BackupFailedItem(
                id: "fixture", filename: "Fixture.heic", reason: "Fixture reason", isPermanent: false,
                source: source)
        }

        private static func row(source: UploadSourceIdentity?, model: BackupProblemPreviewModel) -> some View {
            BackupProblemRow(item: item(source: source), previews: model)
        }

        private static func fittedSize(of row: some View) -> CGSize {
            NSHostingView(rootView: row).fittingSize
        }

        /// Draws a row in a window long enough for its thumbnail task to settle, then caches the drawn pixels.
        private static func capture(_ view: some View) async throws -> DrawnPixels {
            let renderer = LiveRowRenderer(view: view)
            defer { renderer.close() }
            try await renderer.settle()
            return try renderer.snapshot()
        }

        /// The one preview square the row loads, in a color no other row content uses.
        nonisolated fileprivate static func magentaBitmap() -> CGImage? {
            bitmap(red: 1, green: 0, blue: 1)
        }

        nonisolated fileprivate static func cyanBitmap() -> CGImage? {
            bitmap(red: 0, green: 1, blue: 1)
        }

        nonisolated private static func bitmap(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
            let side = 8
            guard
                let context = CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage()
        }
    }

    /// Records every picture request of a preview model.
    @MainActor
    private final class LoadLog {
        private(set) var requested: [String] = []
        var image: CGImage?

        func load(_ uid: PhotoUID) async -> CGImage? {
            requested.append(uid.nodeID)
            return image
        }
    }

    @MainActor
    private final class HeldLoad {
        private(set) var started = false
        private var continuation: CheckedContinuation<CGImage?, Never>?

        func load(_ uid: PhotoUID) async -> CGImage? {
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            continuation?.resume(returning: BackupProblemRowTests.cyanBitmap())
            continuation = nil
        }
    }

    /// Holds the preview model of a mounted row so a test can add or remove it while the row keeps its uid.
    @MainActor
    @Observable
    private final class PreviewModelBox {
        var previews: BackupProblemPreviewModel?
        init(previews: BackupProblemPreviewModel? = nil) { self.previews = previews }
    }

    /// A problem row whose previews model comes from a mutable box, not from the row's initializer.
    private struct BoxedProblemRow: View {
        let item: BackupFailedItem
        let box: PreviewModelBox

        var body: some View {
            BackupProblemRow(item: item, previews: box.previews)
        }
    }

    /// A row view in a live window whose picture task can run. `close` removes the window.
    @MainActor
    private final class LiveRowRenderer {
        private static let width = 320
        private static let height = 80
        private let host: NSHostingView<AnyView>
        private let window: NSWindow

        init(view: some View) {
            let framed = AnyView(
                view.frame(width: CGFloat(Self.width), height: CGFloat(Self.height))
                    .background(Color.white).environment(\.colorScheme, .light))
            host = NSHostingView(rootView: framed)
            host.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
            window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
        }

        func close() {
            window.orderOut(nil)
        }

        /// Lets the mounted row redraw while its picture task settles.
        func settle() async throws {
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }

        func snapshot() throws -> DrawnPixels {
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Self.width, pixelsHigh: Self.height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: Self.width * 4, bitsPerPixel: 32))
            host.cacheDisplay(in: host.bounds, to: rep)
            return DrawnPixels(rep: rep)
        }
    }

    /// The cached pixels of one rendered row: ink for the layout, magenta for the loaded preview square.
    private struct DrawnPixels {
        private static let inkLimit = CGFloat(200) / 255

        let width: Int
        let height: Int
        private let colors: [[NSColor]]

        init(rep: NSBitmapImageRep) {
            let width = rep.pixelsWide
            let height = rep.pixelsHigh
            self.width = width
            self.height = height
            colors = (0..<height).map { y in
                (0..<width).map { x in rep.colorAt(x: x, y: y) ?? NSColor.white }
            }
        }

        /// How many pixels draw content within the given columns.
        func inkCount(columns: Range<Int>) -> Int {
            columns.reduce(0) { count, x in
                count + (0..<height).filter { isDrawn(colors[$0][x]) }.count
            }
        }

        /// Which pixels draw content, from a column on, so identical rows produce identical grids.
        func takeInk(fromColumn column: Int = 0) -> InkGrid {
            InkGrid(
                width: width - column, height: height,
                ink: (0..<height).flatMap { y in (column..<width).map { x in isDrawn(colors[y][x]) } })
        }

        /// The columns of the loaded preview square.
        func magentaColumns() -> Range<Int>? {
            columns { $0.redComponent > 0.78 && $0.greenComponent < 0.24 && $0.blueComponent > 0.78 }
        }

        func cyanColumns() -> Range<Int>? {
            columns { $0.redComponent < 0.24 && $0.greenComponent > 0.78 && $0.blueComponent > 0.78 }
        }

        private func columns(matching predicate: (NSColor) -> Bool) -> Range<Int>? {
            let present = (0..<height).flatMap { y in (0..<width).filter { x in predicate(colors[y][x]) } }
            guard let first = present.min(), let last = present.max() else { return nil }
            return first..<(last + 1)
        }

        private func isDrawn(_ color: NSColor) -> Bool {
            color.redComponent < Self.inkLimit
                || color.greenComponent < Self.inkLimit || color.blueComponent < Self.inkLimit
        }
    }

    /// Which pixels of a row draw content.
    private struct InkGrid: Equatable {
        let width: Int
        let height: Int
        let ink: [Bool]
    }
#endif
