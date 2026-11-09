import Testing

@testable import GridCore

/// Window resizes on iPad (834 pt regular profile, 417 pt compact profile) and the iPhone Duo fold and unfold round
/// trip, measured on the simulator: the size match alone returned a denser level on every round trip.
@Suite struct GridProfileLevelMemoryTests {
    @Test func aRoundTripWithoutZoomReturnsToTheStartingLevel() {
        var memory = GridProfileLevelMemory()
        let regular = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        #expect(regular == 1)
        let compact = memory.level(leaving: "regular", at: 1, entering: "compact") { 1 }
        #expect(compact == 0)
        // A second round trip stays stable.
        #expect(memory.level(leaving: "compact", at: 0, entering: "regular") { 2 } == 1)
        #expect(memory.level(leaving: "regular", at: 1, entering: "compact") { 2 } == 0)
    }

    @Test func manyRoundTripsDoNotCreepTheDensity() {
        var memory = GridProfileLevelMemory()
        var level = 0
        var visited: [Int] = []
        for _ in 0..<6 {
            // The size match alone would return one step denser each time it runs.
            level = memory.level(leaving: "regular", at: level, entering: "compact") { level + 1 }
            level = memory.level(leaving: "compact", at: level, entering: "regular") { level + 1 }
            visited.append(level)
        }
        #expect(visited == [0, 0, 0, 0, 0, 0])
    }

    @Test func aZoomAfterArrivalLetsTheSizeMatchDecide() {
        var memory = GridProfileLevelMemory()
        _ = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        // The person pinched to level 2 in the regular profile.
        #expect(memory.level(leaving: "regular", at: 2, entering: "compact") { 3 } == 3)
    }

    @Test func theFirstVisitUsesTheSizeMatch() {
        var memory = GridProfileLevelMemory()
        var matched = false
        let level = memory.level(leaving: "compact", at: 1, entering: "regular") {
            matched = true
            return 2
        }
        #expect(matched)
        #expect(level == 2)
    }

    @Test func theMemoryDoesNotRunTheSizeMatchWhenItKnowsTheLevel() {
        var memory = GridProfileLevelMemory()
        _ = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        var matched = false
        _ = memory.level(leaving: "regular", at: 1, entering: "compact") {
            matched = true
            return 5
        }
        #expect(!matched)
    }

    @Test func theTwoStepFormOfAHostThatPicksTheLevelInsideARebaseGivesTheSameLevelsAsTheClosureForm() {
        // The iPhone and iPad host asks for the level in one call. The Mac host picks the level inside the scroll
        // rebase, so it asks first and reports the level it used afterwards. Both must walk the same levels.
        var oneCall = GridProfileLevelMemory()
        var twoStep = GridProfileLevelMemory()
        var oneCallLevel = 2
        var twoStepLevel = 2
        var visited: [Int] = []
        for (source, target) in [("regular", "compact"), ("compact", "regular")] + [
            ("regular", "compact"), ("compact", "regular"),
        ] {
            oneCallLevel = oneCall.level(leaving: source, at: oneCallLevel, entering: target) { oneCallLevel + 1 }
            twoStepLevel =
                twoStep.remembered(leaving: source, at: twoStepLevel, entering: target) ?? twoStepLevel + 1
            twoStep.arrived(in: target, at: twoStepLevel)
            #expect(oneCallLevel == twoStepLevel)
            visited.append(twoStepLevel)
        }
        #expect(visited == [3, 2, 3, 2])
    }

    @Test func aProfileSwitchThatTheMemoryDidNotSeeForgetsTheLevels() {
        var memory = GridProfileLevelMemory()
        _ = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        // The grid is in "regular" at level 1 and the memory knows level 0 for "compact".
        _ = memory.level(leaving: "regular", at: 1, entering: "compact") { 5 }
        // Now the grid leaves "regular" again at level 0 without a visit to "compact" that the memory saw: the
        // level number matches the arrival, but the profile does not, so the old levels no longer describe this grid.
        #expect(memory.level(leaving: "regular", at: 0, entering: "compact") { 9 } == 9)
    }

    @Test func resetForgetsTheLevels() {
        var memory = GridProfileLevelMemory()
        _ = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        memory.reset()
        #expect(memory.level(leaving: "regular", at: 1, entering: "compact") { 2 } == 2)
    }
}
