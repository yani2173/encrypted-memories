import Foundation
import Testing

@testable import PhotosCore

@MainActor @Suite struct BackgroundBackupRunProtectionTests {
    private final class Owner {}

    @Test func onlyTheSameControllerAndRunAreProtected() {
        let protection = BackgroundBackupRunProtection()
        let owner = Owner()
        let other = Owner()
        let token = protection.hold(owner: owner, runID: "run")
        #expect(protection.isProtected(owner: owner, runID: "run"))
        #expect(!protection.isProtected(owner: other, runID: "run"))
        #expect(!protection.isProtected(owner: owner, runID: "later"))
        protection.release(token)
        #expect(!protection.isProtected(owner: owner, runID: "run"))
    }

    @Test func eachWindowReleasesOnlyItsOwnProtection() {
        let protection = BackgroundBackupRunProtection()
        let owner = Owner()
        let old = protection.hold(owner: owner, runID: "run")
        let current = protection.hold(owner: owner, runID: "run")
        protection.release(old)
        #expect(protection.isProtected(owner: owner, runID: "run"))
        protection.release(old)
        #expect(protection.isProtected(owner: owner, runID: "run"))
        protection.release(current)
        #expect(!protection.isProtected(owner: owner, runID: "run"))
    }

    @Test func aWindowDoesNotKeepItsControllerAlive() {
        let protection = BackgroundBackupRunProtection()
        var owner: Owner? = Owner()
        weak var released = owner
        let token = protection.hold(owner: owner!, runID: "run")
        owner = nil
        #expect(released == nil)
        protection.release(token)
    }
}
