import Foundation
import Security

/// The writer's Anthropic API key, kept in the macOS Keychain.
enum Keychain {
    private static let service = "LaserFocus"
    private static let account = "anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var apiKey: String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

struct ClaudeReply {
    var text: String
    var toolCalls: [(name: String, input: [String: Any])]
}

enum ClaudeError: LocalizedError {
    case missingKey
    case refused
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Anthropic API key (Coach ▸ Anthropic API Key…) to talk to the coach."
        case .refused: return "The coach couldn't answer that request."
        case .http(let status, let message): return "Claude API error \(status): \(message)"
        case .invalidResponse: return "Unexpected response from the Claude API."
        }
    }
}

/// Minimal client for the Claude Messages API (raw HTTPS; there is no official Swift SDK).
final class ClaudeClient {
    static let model = "claude-opus-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Sends one Messages API request. `completion` is called on the main queue.
    func send(system: String, messages: [[String: Any]], tools: [[String: Any]], effort: String,
              completion: @escaping (Result<ClaudeReply, Error>) -> Void) {
        guard let key = Keychain.apiKey, !key.isEmpty else {
            completion(.failure(ClaudeError.missingKey))
            return
        }

        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort],
            // If a safety classifier declines, let the API retry on a suitable fallback model.
            "fallbacks": "default",
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = ["type": "auto"]
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> Result<ClaudeReply, Error> {
        if let error = error { return .failure(error) }
        guard let http = response as? HTTPURLResponse, let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(ClaudeError.invalidResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Request failed"
            return .failure(ClaudeError.http(http.statusCode, message))
        }
        if json["stop_reason"] as? String == "refusal" {
            return .failure(ClaudeError.refused)
        }

        // Content may also hold thinking and fallback blocks; only text and tool calls matter here.
        var reply = ClaudeReply(text: "", toolCalls: [])
        for block in json["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                reply.text += block["text"] as? String ?? ""
            case "tool_use":
                if let name = block["name"] as? String, let input = block["input"] as? [String: Any] {
                    reply.toolCalls.append((name, input))
                }
            default:
                break
            }
        }
        reply.text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(reply)
    }
}
