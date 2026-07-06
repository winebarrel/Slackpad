import Foundation

/// Posts messages to a Slack Incoming Webhook. No token or scopes required.
struct SlackClient {
    struct PostError: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    /// Retries for a lost connection: 300ms, 600ms.
    private static let retryDelays: [Duration] = [.milliseconds(300), .milliseconds(600)]

    func post(text: String, webhook: URL) async throws {
        guard webhook.scheme == "https" else {
            throw PostError(message: "Webhook URL must be https")
        }
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        // URLSession sometimes reuses a keep-alive connection the server has
        // already dropped, failing with "network connection lost" (-1005). The
        // request never reached Slack, so retry a couple of times before giving
        // up rather than surfacing a spurious error.
        for delay in Self.retryDelays {
            do {
                return try await send(request)
            } catch let error as URLError where error.code == .networkConnectionLost {
                try await Task.sleep(for: delay)
            }
        }
        try await send(request)
    }

    private func send(_ request: URLRequest) async throws {
        // Block redirects that downgrade https -> http so the payload can't be
        // sent in plaintext.
        let (data, response) = try await URLSession.shared.data(for: request, delegate: HTTPSRedirectGuard())
        guard let http = response as? HTTPURLResponse else {
            throw PostError(message: "Invalid response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PostError(message: "HTTP \(http.statusCode) \(body)")
        }
    }
}

/// Follows redirects only when they stay on https.
private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}
