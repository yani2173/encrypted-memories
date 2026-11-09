import XCTest

@testable import TimelineCore

/// Locks the production grid-profile selection table: pointer surfaces keep the original ladders
/// (macOS spacing must not change), touch surfaces resolve dedicated touch ladders with tighter gaps.
/// Touch-compact intentionally starts at two columns so iPhone never renders a giant single-thumbnail tile.
final class TimelineGridProfileResolverTests: XCTestCase {
    private let resolver = TimelineGridProfileConfiguration.production.resolver

    func testPointerWideViewportResolvesRegularProfile() {
        let profile = resolver.profile(for: TimelineGridViewport(layoutWidth: 1200))
        XCTAssertEqual(profile.id, "regularTimeline")
    }

    func testPointerNarrowViewportResolvesCompactProfile() {
        let profile = resolver.profile(for: TimelineGridViewport(layoutWidth: 500))
        XCTAssertEqual(profile.id, "compactTimeline")
    }

    func testDefaultInputAffinityIsPointer() {
        // Call sites that never mention input (the macOS feature) must keep resolving pointer profiles.
        XCTAssertEqual(TimelineGridViewport(layoutWidth: 900).inputAffinity, .pointer)
    }

    func testTouchNarrowViewportResolvesTouchCompactProfile() {
        let profile = resolver.profile(
            for: TimelineGridViewport(layoutWidth: 402, inputAffinity: .touch)
        )
        XCTAssertEqual(profile.id, "touchCompactTimeline")
    }

    func testTouchPortraitTabletStartsAtThreeColumns() {
        let profile = resolver.profile(
            for: TimelineGridViewport(layoutWidth: 768, inputAffinity: .touch)
        )
        XCTAssertEqual(profile.id, "touchCompactTimeline")
        XCTAssertEqual(profile.metrics(level: profile.defaultLevel).nominalColumns, 3)
    }

    func testTouchWideViewportResolvesTouchRegularProfile() {
        for width: CGFloat in [821, 1210] {
            let profile = resolver.profile(
                for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch)
            )
            XCTAssertEqual(profile.id, "touchRegularTimeline", "width \(width)")
            XCTAssertEqual(profile.metrics(level: profile.defaultLevel).nominalColumns, 6)
        }
    }

    func testWideTouchUsesEvenColumnsAndKeepsTheDenseLevels() {
        for width: CGFloat in [821, 867, 951, 1210] {
            let profile = resolver.profile(
                for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
            XCTAssertEqual(profile.id, "touchRegularTimeline", "width \(width)")
            XCTAssertEqual(profile.levels.map(\.nominalColumns), [4, 6, 8, 10, 20, 30], "width \(width)")
            XCTAssertEqual(profile.metrics(level: profile.defaultLevel).nominalColumns, 6, "width \(width)")
        }
        let pointer = resolver.profile(
            for: TimelineGridViewport(layoutWidth: 951, inputAffinity: .pointer))
        XCTAssertEqual(pointer.levels.map(\.nominalColumns), [3, 5, 7, 9, 20, 30])
        for width: CGFloat in [402, 768, 820] {
            let compact = resolver.profile(
                for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
            XCTAssertEqual(compact.id, "touchCompactTimeline", "width \(width)")
            XCTAssertEqual(compact.levels.map(\.nominalColumns), [2, 3, 5, 7, 12, 20], "width \(width)")
            XCTAssertEqual(compact.metrics(level: compact.defaultLevel).nominalColumns, 3, "width \(width)")
        }
    }

    func testTouchProfilesUseTouchSpecificLaddersWithQuarterGaps() throws {
        let pairs = [("compactTimeline", "touchCompactTimeline"), ("regularTimeline", "touchRegularTimeline")]
        for (pointerID, touchID) in pairs {
            let pointer = try XCTUnwrap(resolver.profile(id: pointerID))
            let touch = try XCTUnwrap(resolver.profile(id: touchID))
            XCTAssertEqual(touch.levels.count, pointer.levels.count, touchID)
            for (touchLevel, pointerLevel) in zip(touch.levels, pointer.levels) {
                XCTAssertEqual(
                    touchLevel.supportedContentModes, pointerLevel.supportedContentModes,
                    "\(touchID) level \(touchLevel.levelID) content modes")
                XCTAssertEqual(
                    touchLevel.monthLabels, pointerLevel.monthLabels,
                    "\(touchID) level \(touchLevel.levelID) month labels")
                // ~25% of the pointer gap: never wider than 30%, floored at 1pt for sub-4pt pointer gaps
                // (hairlines below 1pt render unevenly on 2× displays) and 0 stays 0.
                let expectedCeiling = max(pointerLevel.gap * 0.3, pointerLevel.gap == 0 ? 0 : 1)
                XCTAssertLessThanOrEqual(
                    touchLevel.gap, expectedCeiling,
                    "\(touchID) level \(touchLevel.levelID) gap \(touchLevel.gap)")
            }
        }
        let touchCompact = try XCTUnwrap(resolver.profile(id: "touchCompactTimeline"))
        XCTAssertEqual(touchCompact.defaultLevel, 1)
        XCTAssertEqual(touchCompact.levels.map(\.nominalColumns), [2, 3, 5, 7, 12, 20])

        let touchRegular = try XCTUnwrap(resolver.profile(id: "touchRegularTimeline"))
        let pointerRegular = try XCTUnwrap(resolver.profile(id: "regularTimeline"))
        XCTAssertEqual(touchRegular.defaultLevel, 1)
        XCTAssertEqual(touchRegular.levels.map(\.nominalColumns), [4, 6, 8, 10, 20, 30])
        XCTAssertEqual(pointerRegular.levels.map(\.nominalColumns), [3, 5, 7, 9, 20, 30])
    }

    func testUnknownInputAffinityStringIsRejected() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>defaultProfileID</key><string>p</string>
            <key>selectionRules</key><array><dict>
            <key>profileID</key><string>p</string>
            <key>inputAffinity</key><string>stylus</string>
            </dict></array>
            <key>profiles</key><array><dict>
            <key>id</key><string>p</string>
            <key>defaultLevel</key><integer>0</integer>
            <key>levels</key><array><dict>
            <key>id</key><integer>0</integer>
            <key>nominalColumns</key><integer>3</integer>
            <key>gap</key><real>2</real>
            <key>monthLabels</key><false/>
            <key>supportedContentModes</key><array><string>squareFillCrop</string></array>
            <key>defaultContentMode</key><string>squareFillCrop</string>
            </dict></array>
            </dict></array>
            </dict></plist>
            """
        XCTAssertThrowsError(try TimelineGridProfileConfiguration.load(data: Data(plist.utf8))) { error in
            guard case TimelineGridProfileConfigurationError.invalidSelectionInputAffinity = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testAffinityScopedRuleNeverMatchesOtherInput() {
        let rule = TimelineGridProfileSelectionRule(
            profileID: "p", minLayoutWidth: nil, maxLayoutWidth: nil, inputAffinity: .touch
        )
        XCTAssertTrue(rule.matches(TimelineGridViewport(layoutWidth: 500, inputAffinity: .touch)))
        XCTAssertFalse(rule.matches(TimelineGridViewport(layoutWidth: 500, inputAffinity: .pointer)))
    }
}
