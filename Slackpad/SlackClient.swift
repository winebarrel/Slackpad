import Foundation

/// Posts messages to a Slack Incoming Webhook. No token or scopes required.
struct SlackClient {
    struct PostError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func post(text: String, webhook: URL) async throws {
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PostError(message: "Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PostError(message: "HTTP \(http.statusCode) \(body)")
        }
    }
}
