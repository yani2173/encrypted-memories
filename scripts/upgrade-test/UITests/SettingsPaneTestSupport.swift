#if os(macOS)
    enum SettingsPaneTestError: Error, CustomStringConvertible {
        case notAcknowledged(String)

        var description: String {
            switch self {
            case .notAcknowledged(let name):
                return "Settings did not select the \(name) pane after two clicks"
            }
        }
    }

    enum SettingsPaneTestSupport {
        static func select(
            _ name: String, click: () -> Void, isAcknowledged: () -> Bool,
            waitForAcknowledgement: () -> Bool
        ) throws {
            for attempt in 0..<2 {
                if attempt > 0, isAcknowledged() { return }
                click()
                if waitForAcknowledgement() { return }
            }
            throw SettingsPaneTestError.notAcknowledged(name)
        }
    }
#endif
