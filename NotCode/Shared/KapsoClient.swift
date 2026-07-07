import Foundation

/// Minimal client for Kapso's WhatsApp send-message API.
/// Docs: https://docs.kapso.ai/api/meta/whatsapp/messages/send-a-message
struct KapsoClient {
    var apiKey: String
    var phoneNumberID: String

    enum SendError: Error, CustomStringConvertible {
        case http(status: Int, body: String)
        case transport(String)

        var description: String {
            switch self {
            case .http(let status, let body): return "HTTP \(status): \(body)"
            case .transport(let message): return message
            }
        }

        /// WhatsApp only delivers messages within 24h of the recipient's last
        /// message to the number. The fix is on the phone, not in the app.
        var isWindowClosed: Bool {
            if case .http(_, let body) = self {
                return body.contains("24-hour") || body.contains("131047")
            }
            return false
        }

        var userHint: String {
            isWindowClosed
                ? "WhatsApp 24h window closed — send any message (e.g. \"hi\") to your Kapso number from your phone to reopen it"
                : description
        }
    }

    private var endpoint: URL {
        URL(string: "https://api.kapso.ai/meta/whatsapp/v24.0/\(phoneNumberID)/messages")!
    }

    /// Sends an individual free-form text message.
    func sendText(_ body: String, to recipient: String) -> Result<Void, SendError> {
        let payload: [String: Any] = [
            "messaging_product": "whatsapp",
            "recipient_type": "individual",
            "to": recipient,
            "type": "text",
            "text": ["body": body],
        ]
        return post(payload)
    }

    /// Synchronous POST with a short timeout — the hook helper is a
    /// short-lived process and must never hang an agent session.
    private func post(_ payload: [String: Any]) -> Result<Void, SendError> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        var result: Result<Void, SendError> = .failure(.transport("no response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                result = .failure(.transport(error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                result = .success(())
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(.http(status: status, body: String(body.prefix(500))))
            }
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        return result
    }
}
