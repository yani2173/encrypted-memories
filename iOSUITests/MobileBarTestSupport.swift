import CoreGraphics
import XCTest

extension XCUIApplication {
    /// The viewer's menu button. It reports its long accessibility name or the short system name, in English or
    /// German ("More actions" or "More", "Weitere Aktionen" or "Weitere").
    var viewerMoreButton: XCUIElement {
        buttons.matching(
            NSPredicate(format: "label IN %@", ["More actions", "More", "Weitere Aktionen", "Weitere"])
        ).firstMatch
    }

    /// Read a rendered screen pixel in window coordinates, outside the native button backgrounds.
    func screenshotPixel(at point: CGPoint, in window: CGRect) throws -> [UInt8] {
        let image = try XCTUnwrap(screenshot().image.cgImage)
        let x = (point.x - window.minX) * CGFloat(image.width) / window.width
        let y = (point.y - window.minY) * CGFloat(image.height) / window.height
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    /// Tabs are native toolbar buttons when the system presents its bars vertically.
    func barButton(titled title: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Keep native tab queries scoped where UIKit exposes a tab bar, and use the vertical or sidebar role otherwise.
    func tab(titled title: String) -> XCUIElement {
        let tab = tabBars.buttons[title]
        if tab.exists { return tab }
        let button = barButton(titled: title)
        return button.exists ? button : cells[title].firstMatch
    }

    /// Keep the original tab-bar query first. Other roles must match the confirmed native bar geometry.
    func verifiedTab(titled title: String) throws -> XCUIElement {
        let nativeTab = tabBars.buttons[title]
        if nativeTab.exists { return nativeTab }
        let column = try verticalTabColumn()
        let candidate = tab(titled: title)
        XCTAssertTrue(candidate.exists, "The native bar has no \(title) tab")
        XCTAssertFalse(candidate.frame.isEmpty, "The \(title) tab has no frame")
        if let column {
            XCTAssertEqual(
                candidate.frame.midX, column.midX, accuracy: 2, "The \(title) tab is outside the vertical bar column")
        } else {
            XCTAssertEqual(
                candidate.frame.midY, barButton(titled: "Library").frame.midY, accuracy: 2,
                "The \(title) tab is outside the confirmed horizontal tab row")
        }
        return candidate
    }

    /// Vertical navigation exposes the native chevron by its UIKit identifier instead of the previous page title.
    func backButton(to title: String) -> XCUIElement {
        let titled = buttons[title].firstMatch
        return titled.exists ? titled : buttons["BackButton"].firstMatch
    }

    /// Native tabs can form a horizontal row without a tab-bar accessibility role.
    /// Missing controls and unknown layouts still fail the strict vertical checks.
    func verticalTabColumn(titles: [String] = ["Library", "Collections", "Search"]) throws -> CGRect? {
        let frames = try titles.map { title in
            let button = barButton(titled: title)
            return try XCTUnwrap(
                button.waitForExistence(timeout: 10) ? button.frame : nil,
                "The native bar has no \(title) tab")
        }
        let distinctX = frames.indices.allSatisfy { index in
            frames.dropFirst(index + 1).allSatisfy { abs($0.midX - frames[index].midX) > 1 }
        }
        let isHorizontalRow =
            frames.allSatisfy {
                !$0.isEmpty && abs($0.midY - frames[0].midY) <= 2
            } && distinctX
        print("[Native tabs] frames=\(frames) horizontal=\(isHorizontalRow)")
        if isHorizontalRow { return nil }

        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertEqual(frame.midX, frames[0].midX, accuracy: 2, "The tabs do not form a vertical column")
        }
        XCTAssertGreaterThan(abs(frames[0].midY - frames[1].midY), 1)
        let column = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let window = windows.firstMatch.frame
        XCTAssertTrue(
            column.maxX <= window.midX || column.minX >= window.midX,
            "The vertical controls are not beside the content")
        return column
    }

    /// Metal photo elements do not report hittability. Select a complete tile below horizontal navigation,
    /// clear of the vertical controls, so its centre cannot tap the status bar or a bar action.
    func visiblePhoto(beside column: CGRect?) throws -> XCUIElement {
        let photos = descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Photo, ' OR label BEGINSWITH 'Foto, '"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 60), "The library shows no photo")
        let window = windows.firstMatch.frame
        let navigationBottom = navigationBars.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.width > $0.height }
            .reduce(window.minY) { max($0, $1.maxY) }
        let statusBottom = statusBars.allElementsBoundByIndex
            .map(\.frame)
            .reduce(window.minY) { max($0, $1.maxY) }
        let top = max(navigationBottom, statusBottom)
        let isClear: (XCUIElement) -> Bool = { photo in
            let frame = photo.frame
            guard frame.width > 0, frame.height > 0, window.contains(frame), frame.minY >= top else { return false }
            guard let column else { return true }
            return column.midX > window.midX ? frame.maxX <= column.minX : frame.minX >= column.maxX
        }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in photos.allElementsBoundByIndex.contains(where: isClear) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "No complete photo is clear of the bars")
        return try XCTUnwrap(photos.allElementsBoundByIndex.first(where: isClear))
    }
}
