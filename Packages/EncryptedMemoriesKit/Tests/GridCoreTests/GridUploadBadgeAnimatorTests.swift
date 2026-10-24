import Testing

@testable import GridCore

@Suite @MainActor struct GridUploadBadgeAnimatorTests {
    private func pieStep(_ frame: GridUploadBadgeFrame?) -> Int? {
        guard case .pie(let step)? = frame?.glyph else { return nil }
        return step
    }

    @Test func circleFillsSmoothlyInsteadOfJumping() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .waiting, now: 0)
        // The backup reports half the upload at once; the circle moves there frame by frame.
        var previous = 0
        var t = 0.3
        while t < 1.6 {
            let step = pieStep(animator.frame(for: 1, target: .uploading(step: 10), now: t)) ?? -1
            #expect(step >= previous, "the circle never empties while it fills")
            #expect(step - previous <= GridUploadBadgeGlyph.pieSteps / 8, "no visible jump at 120 Hz")
            previous = step
            t += 1.0 / 120
        }
        #expect(previous == GridUploadBadgeGlyph.pieSteps / 2)
        #expect(!animator.isAnimating([1], now: t))
    }

    @Test func restartedUploadNeverEmptiesTheCircle() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 12), now: 0)
        var t = 0.0
        while t < 1 {
            t += 1.0 / 60
            _ = animator.frame(for: 1, target: .uploading(step: 12), now: t)
        }
        let held = pieStep(animator.frame(for: 1, target: .uploading(step: 12), now: t)) ?? 0
        // A new version arrived: the upload starts over and reports little progress.
        for target: GridUploadBadge in [.waiting, .uploading(step: 2), .uploading(step: 8)] {
            for _ in 0..<30 {
                t += 1.0 / 60
                let step = pieStep(animator.frame(for: 1, target: target, now: t)) ?? -1
                #expect(step >= held, "the circle holds its fill while the new upload catches up")
            }
        }
        #expect(!animator.isAnimating([1], now: t), "a held circle needs no frames")
        // The new upload passes the old fill and finishes.
        for _ in 0..<90 {
            t += 1.0 / 60
            _ = animator.frame(for: 1, target: .uploading(step: 20), now: t)
        }
        #expect(pieStep(animator.frame(for: 1, target: .uploading(step: 20), now: t)) == GridUploadBadgeGlyph.pieSteps)
    }

    @Test func backedUpPhotoFillsThenChecksThenFades() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 4), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 4), now: 1)

        // The backup is done and soon reports no badge at all; the grid still finishes the sequence.
        var sawFullCircle = false
        var sawDrawingCheck = false
        var sawFullCheck = false
        var sawFade = false
        var t = 1.0
        var ended: Double?
        while t < 5 {
            let target: GridUploadBadge? = t < 1.5 ? .done : nil
            let frame = animator.frame(for: 1, target: target, now: t)
            switch frame?.glyph {
            case .pie(GridUploadBadgeGlyph.pieSteps)?: sawFullCircle = true
            case .check(let step)? where step < GridUploadBadgeGlyph.checkSteps:
                #expect(sawFullCircle, "the checkmark draws only on the full circle")
                sawDrawingCheck = true
            case .check?:
                sawFullCheck = true
                if let alpha = frame?.alpha, alpha < 1 { sawFade = true }
            case nil:
                if ended == nil { ended = t }
            default:
                break
            }
            t += 1.0 / 60
        }
        #expect(sawFullCircle && sawDrawingCheck && sawFullCheck && sawFade)
        let end = try? #require(ended)
        #expect((end ?? 0) > 2, "the checkmark stays for a moment")
        #expect(!animator.isAnimating([1], now: 5))
    }

    @Test func abandonedUploadFadesOut() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 1)
        let leaving = animator.frame(for: 1, target: nil, now: 1.1)
        #expect(leaving != nil, "the badge fades instead of vanishing")
        #expect(animator.frame(for: 1, target: nil, now: 2) == nil)
        #expect(animator.frame(for: 2, target: nil, now: 2) == nil, "a photo without a badge draws nothing")
    }

    @Test func fixedBadgeFadesInAndOut() {
        let animator = GridUploadBadgeAnimator<Int>()
        let first = animator.frame(for: 1, target: .attention, now: 0)
        #expect(first?.glyph == .attention)
        #expect(animator.isAnimating([1], now: 0.05), "the host keeps drawing while the badge fades in")
        #expect(animator.frame(for: 1, target: .attention, now: 1)?.alpha == 1)
        #expect(!animator.isAnimating([1], now: 1))
        let leaving = animator.frame(for: 1, target: nil, now: 2)
        #expect(leaving?.glyph == .attention, "the badge fades instead of vanishing")
        #expect(animator.isAnimating([1], now: 2))
        #expect(animator.frame(for: 1, target: nil, now: 3) == nil)
    }

    @Test func badgeThatReturnsWhileFadingContinuesFromItsOpacity() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 1)
        _ = animator.frame(for: 1, target: nil, now: 1.2)
        let fading = animator.frame(for: 1, target: nil, now: 1.4)
        let back = animator.frame(for: 1, target: .uploading(step: 10), now: 1.4 + 1.0 / 120)
        let fadingAlpha = fading?.alpha ?? 0
        let backAlpha = back?.alpha ?? 0
        #expect(fadingAlpha < 1)
        #expect(abs(backAlpha - fadingAlpha) < 0.1, "no jump back to full opacity")
    }

    @Test func restingGridKeepsItsBadgesWhenDrawingResumes() {
        let animator = GridUploadBadgeAnimator<Int>()
        let ids = Array(0..<300)
        for id in ids { _ = animator.frame(for: id, target: .waiting, now: 0) }
        for id in ids { _ = animator.frame(for: id, target: .waiting, now: 1) }
        // The grid rests for a minute without drawing, then scrolls.
        for id in ids {
            let frame = animator.frame(for: id, target: .waiting, now: 61)
            #expect(frame?.alpha == 1, "a visible badge must not fade in again after a rest")
        }
    }

    @Test func handoverKeepsTheAnimation() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 20), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 20), now: 2)
        animator.adopt(from: 1, to: 100)
        // The Proton photo continues where the pending tile was: full, no fade-in, no restart from empty.
        let frame = animator.frame(for: 100, target: .done, now: 2.01)
        #expect(frame?.alpha ?? 0 > 0.99)
        if case .pie(let step)? = frame?.glyph { #expect(step == GridUploadBadgeGlyph.pieSteps) }
    }

    @Test func staticGlyphMatchesTheBadge() {
        #expect(GridUploadBadgeGlyph(.waiting) == .pie(0))
        #expect(
            GridUploadBadgeGlyph(.uploading(step: GridUploadBadge.progressSteps)) == .pie(GridUploadBadgeGlyph.pieSteps)
        )
        #expect(GridUploadBadgeGlyph(.done) == .check(GridUploadBadgeGlyph.checkSteps))
        #expect(GridUploadBadgeGlyph(.notBackedUp).symbolName == "icloud.slash")
        #expect(GridUploadBadgeGlyph(.paused) == .paused)
        #expect(GridUploadBadgeGlyph(.paused).symbolName == nil, "the pause bars are drawn, not a symbol")
    }

    @Test func pausedCircleSwapsItsGlyphWithoutFadingInAgain() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 1)

        let paused = animator.frame(for: 1, target: .paused, now: 1.01)
        #expect(paused?.glyph == .paused)
        #expect(paused?.alpha == 1, "the person sees the circle turn into the pause symbol, not a new badge")
        #expect(!animator.isAnimating([1], now: 1.01), "a paused badge needs no frames")

        let resumed = animator.frame(for: 1, target: .uploading(step: 10), now: 2)
        #expect(resumed?.alpha == 1)
        #expect(pieStep(resumed) == GridUploadBadgeGlyph.pieSteps / 2, "the circle keeps its fill after resume")
    }

    @Test func pausedBadgeOfANewPhotoFadesInAndOut() {
        let animator = GridUploadBadgeAnimator<Int>()
        #expect(animator.frame(for: 1, target: .paused, now: 0)?.glyph == .paused)
        #expect(animator.isAnimating([1], now: 0.05))
        #expect(animator.frame(for: 1, target: .paused, now: 1)?.alpha == 1)
        #expect(animator.frame(for: 1, target: nil, now: 2)?.glyph == .paused, "the badge fades instead of vanishing")
        #expect(animator.frame(for: 1, target: nil, now: 3) == nil)
    }

    @Test func anUploadThatFinishesDuringThePauseFillsTheCircleBeforeItsCheckmark() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 1)
        #expect(animator.frame(for: 1, target: .paused, now: 1.01)?.glyph == .paused)

        var pies: [Int] = []
        var sawCheck = false
        var t = 2.0
        while t < 4 {
            let frame = animator.frame(for: 1, target: .done, now: t)
            if let step = pieStep(frame) {
                #expect(!sawCheck, "the circle never comes back after the checkmark")
                pies.append(step)
            } else if case .check? = frame?.glyph {
                sawCheck = true
            }
            t += 1.0 / 60
        }
        #expect((pies.first ?? .max) < GridUploadBadgeGlyph.pieSteps * 3 / 4, "no instant full disc")
        #expect(pies.count > 1, "the circle fills over several frames")
        #expect(pies == pies.sorted(), "the circle never empties while it fills")
        #expect((pies.last ?? 0) >= GridUploadBadgeGlyph.pieSteps - 2, "the circle fills before the checkmark")
        #expect(sawCheck)
    }
}
