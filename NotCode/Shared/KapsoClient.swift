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

        /// Meta rejects free-form messages outside the 24h customer service
        /// window (error 131047 "re-engagement message" and friends). Any 4xx
        /// on a text send is worth retrying as a template.
        var isWorthTemplateRetry: Bool {
            if case .http(let status, _) = self { return (400..<500).contains(status) }
            return false
        }
    }

    private var endpoint: URL {
        URL(string: "https://api.kapso.ai/meta/whatsapp/v24.0/\(phoneNumberID)/messages")!
    }

    /// Sends a free-form text message. Falls back to the configured template
    /// when the 24h window is closed (if `templateName` is non-empty).
    func sendText(_ body: String, to recipient: String,
                  templateName: String, templateLanguage: String) -> Result<Void, SendError> {
        let payload: [String: Any] = [
            "messaging_product": "whatsapp",
            "recipient_type": "individual",
            "to": recipient,
            "type": "text",
            "text": ["body": body],
        ]
        let textResult = post(payload)
        guard case .failure(let error) = textResult, error.isWorthTemplateRetry,
              !templateName.isEmpty
        else { return textResult }

        Log.append("kapso: text send failed (\(error)), retrying as template '\(templateName)'")
        return sendTemplate(templateName, language: templateLanguage,
                            bodyParameter: body, to: recipient)
    }

    func sendTemplate(_ name: String, language: String, bodyParameter: String,
                      to recipient: String) -> Result<Void, SendError> {
        let payload: [String: Any] = [
            "messaging_product": "whatsapp",
            "recipient_type": "individual",
            "to": recipient,
            "type": "template",
            "template": [
                "name": name,
                "language": ["code": language],
                "components": [
                    [
                        "type": "body",
                        "parameters": [["type": "text", "text": bodyParameter]],
                    ]
                ],
            ],
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
