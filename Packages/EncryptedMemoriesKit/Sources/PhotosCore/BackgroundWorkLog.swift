import Foundation
import OSLog

/// A code-owned enumeration whose case names may appear in the background log. Conform only types whose values the
/// code chooses, never values read from a photo, a file, the account or the network.
public protocol BackgroundLogName: RawRepresentable where RawValue == String {}

/// Milestones of background work, written at the notice level, which a Release build keeps. A device log then shows
/// whether and how the app ran in the background. A line holds only fixed words, `BackgroundLogName` names, flags,
/// counts and durations: its keys and values have no initializer for other text.
public struct BackgroundWorkLog: Sendable {
    public enum Category: String, Sendable {
        case photoBackup = "PhotoBackupBackground"
        case smartSearch = "SmartSearchBackground"
        case launch = "BackgroundLaunch"
    }

    /// A field name: a fixed word, or the name of a code-owned enumeration case.
    public struct Key: Sendable, Equatable {
        let text: String

        public init(_ word: StaticString) {
            text = "\(word)"
        }

        public static func name<T: BackgroundLogName>(_ value: T) -> Key {
            Key(text: value.rawValue)
        }

        /// `self.other`, for a count per state and reason.
        public func dot(_ other: Key) -> Key {
            Key(text: text + "." + other.text)
        }

        private init(text: String) {
            self.text = text
        }
    }

    /// A field value: a fixed word, a code-owned name, a flag, a count or a duration.
    public struct Value: Sendable, Equatable {
        let text: String

        public static func word(_ word: StaticString) -> Value {
            Value(text: "\(word)")
        }

        public static func name<T: BackgroundLogName>(_ value: T) -> Value {
            Value(text: value.rawValue)
        }

        public static func flag(_ value: Bool) -> Value {
            Value(text: value ? "yes" : "no")
        }

        public static func count<T: BinaryInteger>(_ value: T) -> Value {
            Value(text: String(value))
        }

        /// Whole milliseconds.
        public static func milliseconds(_ duration: Duration) -> Value {
            let (seconds, attoseconds) = duration.components
            return Value(text: String(seconds * 1000 + attoseconds / 1_000_000_000_000_000))
        }

        /// Whole seconds, for a date relative to now.
        public static func seconds(_ interval: TimeInterval) -> Value {
            Value(text: String(Int(interval.rounded())))
        }

        private init(text: String) {
            self.text = text
        }
    }

    public static let system = persisting(to: .shared)

    /// Writes each line to the unified log and to `file`, which the support file carries.
    public static func persisting(to file: BackgroundWorkLogFile) -> BackgroundWorkLog {
        BackgroundWorkLog { category, line in
            Logger(subsystem: "at.oncloud.encryptedmemories", category: category.rawValue)
                .notice("\(line, privacy: .public)")
            file.append(category.rawValue + " " + line)
        }
    }

    private let sink: @Sendable (Category, String) -> Void

    /// A log that hands each line to `sink`, for tests.
    public init(sink: @escaping @Sendable (Category, String) -> Void) {
        self.sink = sink
    }

    /// Writes `event key=value …`, with the fields in the given order.
    public func notice(_ category: Category, _ event: StaticString, _ fields: [(Key, Value)] = []) {
        sink(category, Self.line(event, fields))
    }

    static func line(_ event: StaticString, _ fields: [(Key, Value)]) -> String {
        (["\(event)"] + fields.map { "\($0.0.text)=\($0.1.text)" }).joined(separator: " ")
    }
}

extension BackgroundWorkLog {
    /// The category of a window's lines.
    public static func category(for kind: BackgroundWindowKind) -> Category {
        kind == .smartSearch ? .smartSearch : .photoBackup
    }

    /// How a window's wait for its account ended, and how long it took.
    public func accountWait<Service>(
        _ kind: BackgroundWindowKind, _ wait: BackgroundAccountWait<Service>, waited: Duration
    ) {
        let result: Value =
            switch wait {
            case .ready: .word("ready")
            case .cannotRun(let outcome): .name(outcome)
            case .notReady: .word("notReady")
            }
        notice(
            Self.category(for: kind), "window.account",
            [(Key("kind"), .name(kind)), (Key("result"), result), (Key("waitMs"), .milliseconds(waited))])
    }

    /// The OS expiration handler of a window ran.
    public func expirationReceived(_ kind: BackgroundWindowKind) {
        notice(Self.category(for: kind), "window.expirationReceived", [(Key("kind"), .name(kind))])
    }

    /// The scheduler accepted the next request of a window, with its earliest begin, or refused it with an error code.
    public func requestSubmitted(_ kind: BackgroundWindowKind, earliestBegin: Date?, errorCode: Int?) {
        var fields: [(Key, Value)] = [(Key("kind"), .name(kind))]
        if let errorCode {
            fields.append((Key("errorCode"), .count(errorCode)))
            notice(Self.category(for: kind), "request.failed", fields)
            return
        }
        fields.append(
            (Key("earliestBeginSeconds"), earliestBegin.map { .seconds($0.timeIntervalSinceNow) } ?? .word("none")))
        notice(Self.category(for: kind), "request.submitted", fields)
    }
}
