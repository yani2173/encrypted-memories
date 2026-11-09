import Foundation

/// Shared admission, buffered transport and independent one-shot HTTP retry budgets.
enum BufferedHTTPExecutor {
    struct Request: Sendable {
        let request: URLRequest
        let credentialGeneration: UInt64
    }

    struct Response: Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    enum Failure: Error {
        case invalidResponse
    }

    static func perform(
        _ initial: Request,
        urlSession: URLSession,
        governor: ProtonRequestGovernor,
        label: ProtonRequestLabel,
        retryOn401: Bool,
        retryOn429: Bool,
        taskDelegate: (any URLSessionTaskDelegate)? = nil,
        retryAfterRateLimit: (Request) throws -> Request,
        refreshAfterUnauthorized: (Request) async throws -> Request?
    ) async throws -> Response {
        var attempt = initial
        var canRetryUnauthorized = retryOn401
        var canRetryRateLimit = retryOn429
        while true {
            let result = try await send(
                attempt.request, urlSession: urlSession, governor: governor,
                label: label, taskDelegate: taskDelegate)
            if result.response.statusCode == 429, canRetryRateLimit {
                canRetryRateLimit = false
                attempt = try retryAfterRateLimit(attempt)
                continue
            }
            if result.response.statusCode == 401, canRetryUnauthorized,
                let retry = try await refreshAfterUnauthorized(attempt)
            {
                canRetryUnauthorized = false
                attempt = retry
                continue
            }
            return result
        }
    }

    /// Each attempt releases its own permit before any retry policy or refresh callback runs.
    private static func send(
        _ request: URLRequest,
        urlSession: URLSession,
        governor: ProtonRequestGovernor,
        label: ProtonRequestLabel,
        taskDelegate: (any URLSessionTaskDelegate)?
    ) async throws -> Response {
        let permit = try await governor.acquire(scope: .api, label: label)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request, delegate: taskDelegate)
        } catch {
            await governor.finish(
                permit, statusCode: nil, cancelled: ProtonRequestStatusClass.isCancellation(error))
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            await governor.finish(permit, statusCode: nil)
            throw Failure.invalidResponse
        }
        await governor.finish(
            permit, statusCode: http.statusCode, retryAfter: ProtonRetryAfter.seconds(from: http))
        return Response(data: data, response: http)
    }
}
