#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import Foundation

    /// Available only in the separate, optimized upgrade build.
    public enum UpgradeTestProbe {
        public static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesUITestFixture")
        }

        public static var seedsAccount: Bool {
            ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesUpgradeSeed")
        }

        public static var accountUID: String {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-EncryptedMemoriesUpgradeCase"), index + 1 < args.count,
                args[index + 1].utf8.count == 32,
                args[index + 1].utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                })
            else {
                fatalError(
                    "The upgrade fixture case identifier must contain exactly 32 ASCII hexadecimal characters (0-9, a-f, A-F)"
                )
            }
            return "upgrade-fixture-account-" + args[index + 1]
        }
        public static let assets = (0..<8).map { PhotoUID(volumeID: "upgrade-fixture", nodeID: "asset-\($0)") }

        public static var endpoint: URL {
            let args = ProcessInfo.processInfo.arguments
            guard isRequested,
                let index = args.firstIndex(of: "-EncryptedMemoriesUpgradeServer"), index + 1 < args.count,
                let url = URL(string: args[index + 1]), url.scheme == "http", url.host == "127.0.0.1",
                url.port != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
            else { fatalError("The upgrade fixture requires a loopback server") }
            return url
        }

        public static func isLoopback(_ url: URL) -> Bool {
            url.scheme == "http" && url.host == "127.0.0.1" && url.port == endpoint.port
                && url.user == nil && url.password == nil
        }

        public static func rejectExternalNetwork() {
            URLProtocol.registerClass(UpgradeTestNetworkFence.self)
        }

        public static func request(_ path: String, body: Data? = nil) async throws -> Data {
            var request = URLRequest(url: endpoint.appendingPathComponent(path))
            request.timeoutInterval = 120
            if let body {
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }

        /// The server holds one selected boundary until the runner kills the old app.
        /// No app store or task algorithm changes at these observation points.
        public static func checkpoint(_ point: String) {
            guard isRequested else { return }
            let semaphore = DispatchSemaphore(value: 0)
            var request = URLRequest(url: endpoint.appendingPathComponent("checkpoint/\(point)"))
            // Outlive the runner's 180-second preparation budget and the server's 240-second hold.
            request.timeoutInterval = 300
            let task = URLSession.shared.dataTask(with: request) {
                _, response, error in
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    fatalError("Upgrade checkpoint failed")
                }
                semaphore.signal()
            }
            task.resume()
            guard semaphore.wait(timeout: .now() + 300) == .success else {
                fatalError("Upgrade checkpoint timed out")
            }
        }
    }

    /// Rejects an accidental real service request before URLSession can send it.
    private final class UpgradeTestNetworkFence: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool {
            guard let url = request.url else { return true }
            return !UpgradeTestProbe.isLoopback(url)
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            UpgradeTestProbe.checkpoint("network.denied")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }
#endif
