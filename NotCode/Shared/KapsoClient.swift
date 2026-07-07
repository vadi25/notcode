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

    /// nil when the phone number ID can't form a valid URL — the helper must
    /// return an error for that, never crash on a force-unwrap.
    var endpoint: URL? {
        let id = phoneNumberID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://api.kapso.ai/meta/whatsapp/v24.0/\(encoded)/messages")
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
        guard let endpoint else {
            return .failure(.transport("invalid WhatsApp phone number ID — check it in Settings"))
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return perform(request).map { _ in () }
    }

    /// An inbound WhatsApp message, for the reply loop's polling.
    struct InboundMessage: Equatable {
        var id: String
        var from: String
        var text: String
        var timestamp: Date
    }

    /// Lists inbound messages received on or after `since` (newest last).
    func listInboundMessages(since: Date) -> Result<[InboundMessage], SendError> {
        guard let endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            return .failure(.transport("invalid WhatsApp phone number ID — check it in Settings"))
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        components.queryItems = [
            URLQueryItem(name: "direction", value: "inbound"),
            URLQueryItem(name: "since", value: iso.string(from: since)),
            URLQueryItem(name: "limit", value: "100"),
        ]
        guard let url = components.url else {
            return .failure(.transport("couldn't build the messages URL"))
        }
        return perform(URLRequest(url: url)).map { data in
            Self.parseInboundMessages(data)
        }
    }

    /// Response: {"data":[{"id":"wamid...","from":"1555...","timestamp":"1700000000",
    ///                     "type":"text","text":{"body":"..."}}, ...]}
    static func parseInboundMessages(_ data: Data) -> [InboundMessage] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let items = object["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let body = (item["text"] as? [String: Any])?["body"] as? String
            else { return nil }
            let stamp = TimeInterval(item["timestamp"] as? String ?? "") ?? 0
            return InboundMessage(
                id: id,
                from: item["from"] as? String ?? "",
                text: body,
                timestamp: Date(timeIntervalSince1970: stamp))
        }.sorted { $0.timestamp < $1.timestamp }
    }

    /// Two phone spellings match when their digits match ("+34 600-111-222"
    /// == "34600111222"). Kapso's `from` and the user's configured number
    /// rarely share formatting.
    static func phoneMatches(_ a: String, _ b: String) -> Bool {
        let digits = { (s: String) in s.filter(\.isNumber) }
        let (da, db) = (digits(a), digits(b))
        return !da.isEmpty && da == db
    }

    /// Synchronous request with a short timeout — the hook helper is a
    /// short-lived process and must never hang an agent session.
    private func perform(_ request: URLRequest) -> Result<Data, SendError> {
        var request = request
        request.timeoutInterval = 5
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        // Kapso sits behind Cloudflare, which bans generic client signatures
        // (error 1010); identify ourselves explicitly.
        request.setValue("NotCode (github.com/vadi25/notcode)", forHTTPHeaderField: "User-Agent")

        var result: Result<Data, SendError> = .failure(.transport("no response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                result = .failure(.transport(error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                result = .success(data ?? Data())
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(.http(status: status, body: String(body.prefix(500))))
            }
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        return result
    }
}
