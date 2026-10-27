import Foundation

enum ClaudeCodeError: LocalizedError {
    case notFound
    case notSignedIn(command: String)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Code wasn't found on this Mac. Install the Claude desktop app or Claude Code, or switch to Coach ▸ Use Anthropic API Key."
        case .notSignedIn(let command):
            return "Claude Code isn't signed in to your Claude account. Open Terminal, run:\n\(command)\nand sign in, then try again."
        case .failed(let message):
            return "Claude Code: \(message)"
        case .timedOut:
            return "Claude Code took too long to answer. Try again."
        }
    }
}

/// Talks to Claude through the Claude Code command-line tool, so the coach runs on the
/// writer's Claude subscription instead of an API key. Each request is one headless
/// `claude -p` run with no tools and no saved session.
final class ClaudeCodeClient {
    /// The Claude Code executable: an installed CLI if there is one, otherwise the copy
    /// bundled with the Claude desktop app (newest version).
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installed = [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0) }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map { URL(fileURLWithPath: $0) }
        if let cli = installed.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return cli
        }

        let bundled = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: bundled.path)) ?? []
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let versionDir = bundled.appendingPathComponent(version)
            for build in (try? FileManager.default.contentsOfDirectory(atPath: versionDir.path)) ?? [] {
                let binary = versionDir.appendingPathComponent("\(build)/claude.app/Contents/MacOS/claude")
                if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
        return nil
    }

    /// The Terminal command that signs this Claude Code in with a Claude subscription.
    static func signInCommand(for binary: URL) -> String {
        "\"\(binary.path)\" auth login --claudeai"
    }

    /// Runs one request. The reply's `message` becomes the text, and a `plan`, when present,
    /// is reported as a `propose_plan` tool call like the API client does. Completes on the main queue.
    func send(system: String, prompt: String, schema: [String: Any], effort: String,
              completion: @escaping (Result<ClaudeReply, Error>) -> Void) {
        guard let binary = Self.locate() else {
            CoachLog.write("Claude Code not found")
            completion(.failure(ClaudeCodeError.notFound))
            return
        }
        guard let schemaData = try? JSONSerialization.data(withJSONObject: schema),
              let schemaText = String(data: schemaData, encoding: .utf8) else {
            completion(.failure(ClaudeCodeError.failed("Invalid response schema")))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(binary: binary, system: system, prompt: prompt, schema: schemaText, effort: effort)
            if case .failure(let error) = result {
                CoachLog.write("Claude Code request failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func run(binary: URL, system: String, prompt: String, schema: String,
                            effort: String) -> Result<ClaudeReply, Error> {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-p",
            "--output-format", "json",
            "--system-prompt", system,
            "--json-schema", schema,
            "--effort", effort,
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        // An empty working folder, so no project's CLAUDE.md or settings get pulled in.
        let workspace = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaserFocus/coach", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        process.currentDirectoryURL = workspace

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(ClaudeCodeError.failed(error.localizedDescription))
        }
        input.fileHandleForWriting.write(Data(prompt.utf8))
        input.fileHandleForWriting.closeFile()

        var timedOut = false
        let deadline = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: deadline)
        // Read before waiting so a large reply can't fill the pipe and stall the process.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        if timedOut { return .failure(ClaudeCodeError.timedOut) }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let detail = String(data: stderr.isEmpty ? data : stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(ClaudeCodeError.failed(detail.isEmpty ? "exited with status \(process.terminationStatus)" : String(detail.prefix(300))))
        }

        let resultText = json["result"] as? String ?? ""
        if json["is_error"] as? Bool == true {
            let lowered = resultText.lowercased()
            if lowered.contains("authenticat") || lowered.contains("oauth") || lowered.contains("log in")
                || lowered.contains("login") || lowered.contains("not logged") {
                return .failure(ClaudeCodeError.notSignedIn(command: signInCommand(for: binary)))
            }
            return .failure(ClaudeCodeError.failed(resultText.isEmpty ? "request failed" : resultText))
        }

        // Prefer the validated structured output; fall back to JSON or plain text in `result`.
        var structured = json["structured_output"] as? [String: Any]
        if structured == nil, let resultData = resultText.data(using: .utf8) {
            structured = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        }
        var reply = ClaudeReply(text: "", toolCalls: [], structured: structured)
        if let structured = structured {
            reply.text = (structured["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let plan = structured["plan"] as? [String: Any] {
                reply.toolCalls.append(("propose_plan", plan))
            }
        } else {
            reply.text = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return .success(reply)
    }
}
