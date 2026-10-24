import XCTest

/// Creates the app for every UI test. XCTest launches it with `OS_ACTIVITY_DT_MODE` set and stdio on a pseudo
/// terminal, so the system log, including XCTest's own per-attribute automation log inside the app, is mirrored to
/// stderr. Every accessibility query then writes thousands of lines from the app's main thread; on a loaded host
/// those writes block and the query times out. The system log keeps every entry for `log stream` and Console.
enum UITestApplication {
    static func make() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS_ACTIVITY_DT_MODE"] = "NO"
        return app
    }
}
