import Foundation
import GridCore
import Testing
import TimelineCore

@testable import TimelineFeature

@Suite struct TimelineGridProfileConfigurationTests {
    @Test func bundledGridProfilesLoadRegularAndCompactProfiles() throws {
        let config = try TimelineGridProfileConfiguration.bundled()
        let regular = try #require(config.profile(id: "regularTimeline"))
        let compact = try #require(config.profile(id: "compactTimeline"))

        #expect(config.defaultProfile.id == "regularTimeline")
        #expect(regular.defaultLevel == 3)
        #expect(regular.levels.map(\.nominalColumns) == [3, 5, 7, 9, 20, 30])
        #expect(regular.showsMonthLabels(level: 3) == false)
        #expect(regular.showsMonthLabels(level: 4) == true)

        #expect(compact.defaultLevel == 2)
        #expect(compact.levels.map(\.nominalColumns) == [1, 2, 3, 5, 12, 20])
        #expect(
            SquareTileGridEngine(sectionCounts: [100], profile: compact).resolvedMetrics(level: 0, width: 390).columns
                == 1)

        #expect(
            config.selectionRules == [
                TimelineGridProfileSelectionRule(
                    profileID: "touchCompactTimeline", minLayoutWidth: nil, maxLayoutWidth: 820, inputAffinity: .touch
                ),
                TimelineGridProfileSelectionRule(
                    profileID: "touchRegularTimeline", minLayoutWidth: nil, maxLayoutWidth: nil, inputAffinity: .touch
                ),
                TimelineGridProfileSelectionRule(
                    profileID: "compactTimeline", minLayoutWidth: nil, maxLayoutWidth: 640),
            ])
        #expect(config.resolver.profile(for: TimelineGridViewport(layoutWidth: 640)).id == "compactTimeline")
        #expect(config.resolver.profile(for: TimelineGridViewport(layoutWidth: 641)).id == "regularTimeline")

        // Touch viewports resolve dedicated touch ladders. Touch-compact is intentionally not a pointer
        // mirror: it starts at two columns so iPhone never renders a giant single-thumbnail tile.
        let touchCompact = try #require(config.profile(id: "touchCompactTimeline"))
        let touchRegular = try #require(config.profile(id: "touchRegularTimeline"))
        #expect(touchCompact.defaultLevel == 1)
        #expect(touchCompact.levels.map(\.nominalColumns) == [2, 3, 5, 7, 12, 20])
        #expect(touchRegular.defaultLevel == 1)
        #expect(touchRegular.levels.map(\.nominalColumns) == [4, 6, 8, 10, 20, 30])
        #expect(
            config.resolver.profile(
                for: TimelineGridViewport(layoutWidth: 820, inputAffinity: .touch)
            ).id == "touchCompactTimeline")
        #expect(
            config.resolver.profile(
                for: TimelineGridViewport(layoutWidth: 1024, inputAffinity: .touch)
            ).id == "touchRegularTimeline")
    }

    @Test func invalidDefaultLevelIsRejected() throws {
        let data = try plistData([
            "defaultProfileID": "broken",
            "profiles": [
                [
                    "id": "broken",
                    "defaultLevel": 3,
                    "levels": [level(id: 0, columns: 1, transition: nil)],
                ]
            ],
        ])

        do {
            _ = try TimelineGridProfileConfiguration.load(data: data)
            Issue.record("invalid default level must be rejected")
        } catch let error as TimelineGridProfileConfigurationError {
            #expect(error.description.contains("default level"))
        }
    }

    @Test func omittedIntermediateTransitionIsDerivedFromLevelSemantics() throws {
        let data = try plistData([
            "defaultProfileID": "regular",
            "profiles": [
                [
                    "id": "regular",
                    "defaultLevel": 0,
                    "levels": [
                        level(
                            id: 0, columns: 3, transition: nil,
                            supportedContentModes: ["aspectFitInsideSquare", "squareFillCrop"],
                            defaultContentMode: "aspectFitInsideSquare"),
                        level(
                            id: 1, columns: 5, transition: nil,
                            supportedContentModes: ["aspectFitInsideSquare", "squareFillCrop"],
                            defaultContentMode: "aspectFitInsideSquare"),
                    ],
                ]
            ],
        ])

        let config = try TimelineGridProfileConfiguration.load(data: data)
        let profile = try #require(config.profile(id: "regular"))
        #expect(profile.metrics(level: 0).transitionKindToNext == .focusRowRelayout)
    }

    @Test func explicitTransitionMustMatchLevelSemantics() throws {
        let data = try plistData([
            "defaultProfileID": "regular",
            "profiles": [
                [
                    "id": "regular",
                    "defaultLevel": 0,
                    "levels": [
                        level(
                            id: 0, columns: 3, transition: "denseOverviewZoom",
                            supportedContentModes: ["aspectFitInsideSquare", "squareFillCrop"],
                            defaultContentMode: "aspectFitInsideSquare"),
                        level(
                            id: 1, columns: 5, transition: nil,
                            supportedContentModes: ["aspectFitInsideSquare", "squareFillCrop"],
                            defaultContentMode: "aspectFitInsideSquare"),
                    ],
                ]
            ],
        ])

        do {
            _ = try TimelineGridProfileConfiguration.load(data: data)
            Issue.record("semantic transition mismatches must be rejected")
        } catch let error as TimelineGridProfileConfigurationError {
            #expect(error.description.contains("does not match semantic transition focusRowRelayout"))
        }
    }

    @Test func unknownSelectionProfileIsRejected() throws {
        let data = try plistData(
            validConfig(selectionRules: [
                [
                    "profileID": "missing",
                    "maxLayoutWidth": 640,
                ]
            ]))

        do {
            _ = try TimelineGridProfileConfiguration.load(data: data)
            Issue.record("selection rules must reference a configured profile")
        } catch let error as TimelineGridProfileConfigurationError {
            #expect(error.description.contains("unknown profile id missing"))
        }
    }

    @Test func invalidSelectionRangeIsRejected() throws {
        let data = try plistData(
            validConfig(selectionRules: [
                [
                    "profileID": "regular",
                    "minLayoutWidth": 800,
                    "maxLayoutWidth": 640,
                ]
            ]))

        do {
            _ = try TimelineGridProfileConfiguration.load(data: data)
            Issue.record("selection rule min/max ranges must be validated")
        } catch let error as TimelineGridProfileConfigurationError {
            #expect(error.description.contains("minLayoutWidth 800.0 above maxLayoutWidth 640.0"))
        }
    }

    private func plistData(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private func validConfig(selectionRules: [[String: Any]]) -> [String: Any] {
        [
            "defaultProfileID": "regular",
            "selectionRules": selectionRules,
            "profiles": [
                [
                    "id": "regular",
                    "defaultLevel": 0,
                    "levels": [level(id: 0, columns: 1, transition: nil)],
                ]
            ],
        ]
    }

    private func level(
        id: Int,
        columns: Int,
        transition: String?,
        supportedContentModes: [String] = ["squareFillCrop"],
        defaultContentMode: String = "squareFillCrop"
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "nominalColumns": columns,
            "gap": 0,
            "monthLabels": false,
            "supportedContentModes": supportedContentModes,
            "defaultContentMode": defaultContentMode,
        ]
        if let transition {
            result["transitionKindToNext"] = transition
        }
        return result
    }
}
