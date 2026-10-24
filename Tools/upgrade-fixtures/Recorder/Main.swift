import Foundation

@main struct UpgradeFixtureRecorder {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["UPGRADE_RECORD_ROOT"], let external = environment["UPGRADE_RECORD_ORACLE"],
            let scenario = CommandLine.arguments.dropFirst().first
        else {
            throw FixtureFailure(description: "Recorder needs a scenario and isolated recording paths")
        }
        let oracleURL = URL(fileURLWithPath: external)
        let oracle = FixtureOracle(externalURL: oracleURL)
        try JSONEncoder().encode(oracle).write(to: oracleURL)
        try await FixtureWorkloads.run(scenario, root: URL(fileURLWithPath: path), recording: true, oracle: oracle)
    }
}
