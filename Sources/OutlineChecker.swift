import Foundation

extension Notification.Name {
    /// Posted (object: the checker) when a check starts, finishes or fails.
    static let outlineCheckChanged = Notification.Name("LaserFocusOutlineCheckChanged")
}

/// Asks Claude which points of the writing outline the text already covers. Uses the same
/// connection as the coach: Claude Code on the writer's subscription, or an API key.
final class OutlineChecker {
    private(set) var isChecking = false { didSet { notify() } }
    private(set) var lastError: String? { didSet { notify() } }

    private let store: WritingOutlineStore
    private let client = ClaudeClient()
    private let claudeCode = ClaudeCodeClient()
    private let settings = Settings.shared
    /// Long drafts are cut here, far beyond any essay or chapter.
    private static let maxCharacters = 300_000

    init(store: WritingOutlineStore) {
        self.store = store
    }

    private func notify() {
        NotificationCenter.default.post(name: .outlineCheckChanged, object: self)
    }

    func check(text: String, title: String) {
        guard !isChecking else { return }
        let points = store.points.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !points.isEmpty else {
            lastError = "Add some points to the outline first."
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "There's no text to check yet. Start writing, then check again."
            return
        }

        isChecking = true
        lastError = nil
        let wordCount = TextStats.words(in: text)
        let completion: (Result<ClaudeReply, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            self.isChecking = false
            switch result {
            case .success(let reply):
                let input = reply.structured
                    ?? reply.toolCalls.first { $0.name == Self.toolName }?.input
                if let input = input, self.apply(input, wordCount: wordCount) { return }
                self.lastError = "Claude's answer couldn't be read. Try again."
                CoachLog.write("Outline check: unreadable reply")
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }

        let prompt = Self.prompt(outline: store.promptText(includeIDs: true), text: text, title: title)
        switch settings.coachBackend {
        case .claudeCode:
            claudeCode.send(system: Self.instructions, prompt: prompt, schema: Self.schema,
                            effort: "medium", completion: completion)
        case .api:
            let tool: [String: Any] = [
                "name": Self.toolName,
                "description": "Report, for every outline point, whether the draft covers it.",
                "strict": true,
                "input_schema": Self.schema,
            ]
            client.send(system: Self.instructions, messages: [["role": "user", "content": prompt]],
                        tools: [tool], effort: "medium", forcedTool: Self.toolName, completion: completion)
        }
    }

    private func apply(_ input: [String: Any], wordCount: Int) -> Bool {
        guard let items = input["points"] as? [[String: Any]] else { return false }
        var results: [String: (status: CoverageStatus, evidence: String?, comment: String?)] = [:]
        for item in items {
            guard let id = item["id"] as? String,
                  let status = (item["status"] as? String).flatMap(CoverageStatus.init(rawValue:)) else { continue }
            let evidence = (item["evidence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let comment = (item["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            results[id] = (status, evidence?.isEmpty == false && status != .open ? evidence : nil,
                           comment?.isEmpty == false ? comment : nil)
        }
        guard !results.isEmpty else { return false }
        store.applyCheck(results, summary: input["summary"] as? String, wordCount: wordCount)
        return true
    }

    // MARK: Prompt

    private static let toolName = "report_coverage"

    private static func prompt(outline: String, text: String, title: String) -> String {
        var draft = text
        if (draft as NSString).length > maxCharacters {
            draft = (draft as NSString).substring(to: maxCharacters) + "\n[…the rest of the draft was cut…]"
        }
        return """
        <outline>
        \(outline)
        </outline>

        <draft title="\(title.replacingOccurrences(of: "\"", with: "'"))">
        \(draft)
        </draft>

        Check every outline point against the draft.
        """
    }

    private static let instructions = """
    You help a writer keep track of their writing outline inside LaserFocus, a Markdown writing app. \
    The outline lists what they planned to say, written before or while drafting; each point starts \
    with its id in square brackets, and indented points belong to the point above them. You get the \
    outline and the draft and decide, for every point, how far the draft has got with it:

    - "done": the draft makes this point substantially, even if in different words or a different order.
    - "partial": the draft touches on it, but something the point calls for is missing or only hinted at.
    - "open": the draft doesn't cover it yet.

    Judge by meaning, not by matching words. The outline and draft may be in any language (often \
    Indonesian or English), even different ones. A parent point is done only when its essential \
    sub-points are.

    For every point return its id exactly as given, a status, evidence and a comment:
    - evidence: for done or partial points, a passage copied exactly, character for character, from \
    the draft (5 to 25 words) where the point is covered best, so the app can find it. Empty for open points.
    - comment: one short sentence in the language of the outline. For partial points, say what's \
    missing; for open points, a concrete hint for writing it; for done points, a few words of what \
    covers it.

    Also give a summary: one or two warm, brief sentences in the outline's language on overall \
    progress and which point to write next. Plain text, no Markdown.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["points", "summary"],
        "properties": [
            "summary": ["type": "string", "description": "Overall progress and what to write next."],
            "points": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "status", "evidence", "comment"],
                    "properties": [
                        "id": ["type": "string", "description": "The point's id, without brackets."],
                        "status": ["type": "string", "enum": ["done", "partial", "open"]],
                        "evidence": ["type": "string", "description": "Exact quote from the draft, or empty."],
                        "comment": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]
}
