import Foundation
import Security

/// Secrets kept in the macOS Keychain: the Anthropic API key and the GitHub token for sync.
enum Keychain {
    private static let service = "LaserFocus"
    private static let apiKeyAccount = "anthropic-api-key"
    static let gitHubTokenAccount = "github-token"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var apiKey: String? { string(for: apiKeyAccount) }

    static var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }

    /// Saves (or, with nil, removes) the key. Returns nil on success, else a description of the failure.
    @discardableResult
    static func setAPIKey(_ key: String?) -> String? { set(key, for: apiKeyAccount) }

    static func string(for account: String) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves (or, with nil, removes) a secret. Returns nil on success, else a description of the failure.
    @discardableResult
    static func set(_ value: String?, for account: String) -> String? {
        let deleted = SecItemDelete(query(account) as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return deleted == errSecSuccess || deleted == errSecItemNotFound ? nil : message(for: deleted)
        }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { return message(for: status) }
        // Read it back: a write the app can't read later is as good as no write.
        return string(for: account) == value ? nil : "The value was written but could not be read back from the Keychain."
    }

    private static func message(for status: OSStatus) -> String {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
        return "\(text) (OSStatus \(status))"
    }
}

struct ClaudeReply {
    var text: String
    var toolCalls: [(name: String, input: [String: Any])]
    /// The whole JSON reply when Claude Code was given a schema.
    var structured: [String: Any]? = nil
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
    /// `forcedTool` names a tool Claude must call, for replies that have to follow its schema.
    func send(system: String, messages: [[String: Any]], tools: [[String: Any]], effort: String,
              forcedTool: String? = nil, useFallbacks: Bool = true,
              completion: @escaping (Result<ClaudeReply, Error>) -> Void) {
        guard let key = Keychain.apiKey, !key.isEmpty else {
            CoachLog.write("No API key found in the Keychain")
            completion(.failure(ClaudeError.missingKey))
            return
        }

        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort],
        ]
        if useFallbacks {
            // If a safety classifier declines, let the API retry on a suitable fallback model.
            body["fallbacks"] = "default"
        }
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = forcedTool.map { ["type": "tool", "name": $0] } ?? ["type": "auto"]
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if useFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async {
                // Fallbacks are an optional safety net: if this account or API rejects them, retry without.
                if useFallbacks, case .failure(ClaudeError.http(400, let message)) = result,
                   message.lowercased().contains("fallback") || message.lowercased().contains("beta") {
                    CoachLog.write("Retrying without fallbacks after: \(message)")
                    self.send(system: system, messages: messages, tools: tools, effort: effort,
                              forcedTool: forcedTool, useFallbacks: false, completion: completion)
                    return
                }
                if case .failure(let error) = result {
                    CoachLog.write("Request failed: \(error.localizedDescription)")
                }
                completion(result)
            }
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

/// Coach diagnostics in ~/Library/Logs/LaserFocus/coach.log. Never contains the API key or document text.
enum CoachLog {
    static let url: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/LaserFocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("coach.log")
    }()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
