import Foundation
import Testing

@testable import PhotosCore

@Suite struct BackgroundWorkLogTests {
    private enum Kind: String, BackgroundLogName { case photoBackup }

    @Test func aLineHoldsTheEventAndItsFieldsInOrder() {
        let lines = BackgroundLogLines()
        let log = BackgroundWorkLog { lines.append("\($0.rawValue) \($1)") }
        log.notice(
            .photoBackup, "window.began",
            [
                (.init("kind"), .name(Kind.photoBackup)), (.init("scene"), .flag(false)),
                (.init("waitMs"), .milliseconds(.milliseconds(1_250))),
                (.init("earliestBeginSeconds"), .seconds(899.6)),
                (.name(Kind.photoBackup).dot(.init("rows")), .count(3)), (.init("reason"), .word("none")),
            ])
        log.notice(.launch, "account.start")
        #expect(
            lines.values == [
                "PhotoBackupBackground window.began kind=photoBackup scene=no waitMs=1250 earliestBeginSeconds=900"
                    + " photoBackup.rows=3 reason=none",
                "BackgroundLaunch account.start",
            ])
    }
}

final class BackgroundLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var values: [String] { lock.withLock { lines } }

    func append(_ line: String) { lock.withLock { lines.append(line) } }
}
