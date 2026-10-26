import AppKit

/// Where the writer stands against their approved plan.
struct PlanStatus {
    let unit: String
    let current: Int
    let doneToday: Int
    /// Today's target; 0 when today isn't a writing day.
    let todayGoal: Int
    /// How far behind the plan the writer was at the start of today.
    let behind: Int
    let totalTarget: Int
    let daysLeft: Int
    let nextMilestone: Milestone?

    var summary: String {
        var parts = ["Total so far: \(current) of \(totalTarget) \(unit)."]
        if todayGoal > 0 {
            parts.append("Today: \(doneToday) of \(todayGoal) \(unit) written.")
        } else {
            parts.append("Today is not a planned writing day (\(doneToday) \(unit) written anyway).")
        }
        parts.append(behind > 0 ? "Behind the plan by \(behind) \(unit) from previous days." : "On track with the plan.")
        parts.append("\(daysLeft) day\(daysLeft == 1 ? "" : "s") left until the deadline.")
        if let milestone = nextMilestone {
            parts.append("Next milestone: \"\(milestone.title)\" — \(milestone.target) \(unit) by \(milestone.due).")
        }
        return parts.joined(separator: " ")
    }
}

/// The motivation coach for one open document.
///
/// - Planning: a short interview with Claude, which then proposes a plan through the
///   `propose_plan` tool. The writer approves it or asks for changes.
/// - Reminders: every time the document is opened, the coach recaps today's goal.
/// - Nudges: typing patterns are watched locally (long pauses mid-sentence, lots of
///   deleting and retyping, going idle), and only then is Claude asked for a short message.
final class WritingCoach {
    let store: CoachStore
    var textProvider: () -> String = { "" }
    var caretProvider: () -> Int = { 0 }
    var titleProvider: () -> String = { "Untitled" }
    var isWindowActive: () -> Bool = { false }
    /// Called when the coach speaks up on its own, so the panel can be revealed.
    var onNudge: (() -> Void)?

    private(set) var isThinking = false { didSet { notify() } }
    private(set) var lastError: String? { didSet { notify() } }

    private let client = ClaudeClient()
    private let claudeCode = ClaudeCodeClient()
    private let settings = Settings.shared
    private var timer: Timer?
    private var edits: [(date: Date, inserted: Int, deleted: Int)] = []
    private var lastTyping: Date?
    private var typedSinceNudge = false
    private var lastNudge = Date.distantPast
    private var started = false

    private static let nudgeCooldown: TimeInterval = 8 * 60
    private static let stuckPause: TimeInterval = 90
    private static let idlePause: TimeInterval = 4 * 60

    init(store: CoachStore) {
        self.store = store
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts watching and greets the writer. Call once when the window appears.
    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkForNudge() }
        greet()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func notify() {
        NotificationCenter.default.post(name: .coachChanged, object: store)
    }

    // MARK: Writer activity

    func recordEdit(inserted: Int, deleted: Int) {
        let now = Date()
        edits.append((now, inserted, deleted))
        edits.removeAll { now.timeIntervalSince($0.date) > 120 }
        lastTyping = now
        typedSinceNudge = true
    }

    /// Updates today's progress and celebrates when the daily goal is reached.
    func textDidChange() {
        guard let plan = store.data.plan else { return }
        let count = self.count(in: textProvider(), unit: plan.unit)
        let today = Self.dayKey(Date())
        guard store.data.progress[today] != count else { return }
        store.update(markEdited: false) { $0.progress[today] = count }

        if let status = status(), status.todayGoal > 0, status.doneToday >= status.todayGoal,
           store.data.celebratedOn != today {
            store.update { $0.celebratedOn = today }
            speak(event: "The writer just reached today's goal (\(status.doneToday) of \(status.todayGoal) \(status.unit)). Celebrate briefly and tell them what's next.",
                  fallback: "Today's goal reached — \(status.doneToday) \(status.unit). Great work! Anything more is a head start on tomorrow.")
        }
    }

    func checkForNudge() {
        guard settings.coachNudges, isWindowActive(), !isThinking, typedSinceNudge,
              let lastTyping = lastTyping,
              Date().timeIntervalSince(lastNudge) > Self.nudgeCooldown else { return }
        let now = Date()
        let idle = now.timeIntervalSince(lastTyping)
        let recent = edits.filter { now.timeIntervalSince($0.date) <= 90 }
        let inserted = recent.reduce(0) { $0 + $1.inserted }
        let deleted = recent.reduce(0) { $0 + $1.deleted }

        if deleted >= 15 && Double(deleted) >= Double(inserted) * 0.6 && idle < 30 {
            nudge(event: "The writer has been deleting and retyping a lot over the last minute and a half; they seem stuck on a word or phrase. Offer quick, concrete help.",
                  fallback: "Rewriting the same bit again? Leave a rough version and keep going — you can polish it later.")
        } else if idle >= Self.stuckPause && idle < Self.idlePause && isMidSentence() {
            nudge(event: "The writer stopped typing in the middle of a sentence about \(Int(idle)) seconds ago. They may be searching for a word. Offer a gentle nudge.",
                  fallback: "Searching for the right word? Put a placeholder like [word] and finish the sentence — momentum first.")
        } else if idle >= Self.idlePause {
            nudge(event: "The writer hasn't typed for \(Int(idle / 60)) minutes while the document is open. Encourage them to get back to it.",
                  fallback: "Still there? Even two more sentences keep the streak alive.")
        }
    }

    private func nudge(event: String, fallback: String) {
        lastNudge = Date()
        typedSinceNudge = false
        speak(event: event, fallback: fallback)
        onNudge?()
    }

    private func isMidSentence() -> Bool {
        let ns = textProvider() as NSString
        let caret = min(caretProvider(), ns.length)
        guard caret > 0 else { return false }
        let previous = ns.substring(with: NSRange(location: caret - 1, length: 1))
        return !".!?:\n".contains(previous)
    }

    // MARK: Conversation

    /// Opening message each time the document is opened.
    private func greet() {
        if store.data.plan != nil, let status = status() {
            speak(event: "The writer just opened this document. Greet them, remind them of today's goal and where they stand against the plan, and motivate them to start.",
                  fallback: localReminder(status))
        } else if store.data.chat.isEmpty {
            store.update(markEdited: false) {
                $0.chat.append(ChatEntry(role: .assistant, text: "Hi! I'm your writing coach. Want a plan for this piece? Click \"Plan my writing\" and I'll ask a few questions, then suggest a schedule you can approve or change."))
            }
        }
    }

    func startPlanning() {
        let revising = store.data.plan != nil
        speak(event: revising
              ? "The writer wants to revise their writing plan. Ask what should change (one question at a time), then propose the revised plan."
              : "The writer clicked \"Plan my writing\". Start the planning interview with your first question.",
              fallback: nil, effort: "medium")
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update { $0.chat.append(ChatEntry(role: .user, text: trimmed)) }
        converse(effort: "medium", fallback: nil)
    }

    func approvePendingPlan() {
        guard let plan = store.data.pendingPlan else { return }
        let count = self.count(in: textProvider(), unit: plan.unit)
        let today = Self.dayKey(Date())
        store.update {
            $0.plan = plan
            $0.pendingPlan = nil
            $0.approvedOn = today
            $0.baseline = count
            $0.progress = [today: count]
            $0.chat.append(ChatEntry(role: .user, text: "[LaserFocus: The writer approved the plan.]", hidden: true))
            $0.chat.append(ChatEntry(role: .assistant, text: "Plan approved! I'll remind you of it every time you open this document, and check in if you get stuck."))
        }
    }

    /// Adds a hidden app event to the conversation and asks Claude to respond to it.
    private func speak(event: String, fallback: String?, effort: String = "low") {
        store.update(markEdited: false) {
            $0.chat.append(ChatEntry(role: .user, text: "[LaserFocus: \(event)]", hidden: true))
        }
        converse(effort: effort, fallback: fallback)
    }

    private func converse(effort: String, fallback: String?) {
        isThinking = true
        lastError = nil
        let completion: (Result<ClaudeReply, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            self.isThinking = false
            switch result {
            case .success(let reply):
                self.handle(reply)
            case .failure(let error):
                if let fallback = fallback {
                    self.store.update(markEdited: false) { $0.chat.append(ChatEntry(role: .assistant, text: fallback)) }
                }
                // Until the coach is set up, automatic messages quietly use the local fallback.
                if !(Self.isSetupProblem(error) && fallback != nil) {
                    self.lastError = error.localizedDescription
                }
            }
        }

        switch settings.coachBackend {
        case .claudeCode:
            claudeCode.send(system: systemPrompt(), prompt: transcriptPrompt(), schema: Self.replySchema,
                            effort: effort, completion: completion)
        case .api:
            client.send(system: systemPrompt(), messages: apiMessages(), tools: [Self.proposePlanTool],
                        effort: effort, completion: completion)
        }
    }

    /// Errors that mean the coach isn't connected yet, rather than that a request failed.
    static func isSetupProblem(_ error: Error) -> Bool {
        switch error {
        case ClaudeError.missingKey, ClaudeCodeError.notFound, ClaudeCodeError.notSignedIn: return true
        default: return false
        }
    }

    /// True when the last failure was Claude Code needing a sign-in; the panel offers the command.
    var needsClaudeCodeSignIn: Bool {
        guard let binary = ClaudeCodeClient.locate(), let error = lastError else { return false }
        return error.contains(ClaudeCodeClient.signInCommand(for: binary))
    }

    private func handle(_ reply: ClaudeReply) {
        let proposal = reply.toolCalls.first { $0.name == "propose_plan" }.flatMap { WritingPlan.fromToolInput($0.input) }
        store.update {
            if !reply.text.isEmpty {
                $0.chat.append(ChatEntry(role: .assistant, text: reply.text))
            }
            if let plan = proposal {
                $0.pendingPlan = plan
                $0.chat.append(ChatEntry(role: .assistant, text: "", plan: plan))
            }
        }
        if reply.text.isEmpty && proposal == nil {
            lastError = "The coach returned an empty reply."
        }
    }

    /// The stored chat as Messages API turns: text only, alternating roles, starting with the writer.
    private func apiMessages() -> [[String: Any]] {
        var turns: [(role: String, text: String)] = []
        for entry in store.data.chat.suffix(40) {
            var text = entry.text
            if let plan = entry.plan {
                text = "I proposed this plan (shown to the writer as a card with Approve and Request changes buttons):\n" + plan.description
            }
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.role == entry.role.rawValue {
                turns[turns.count - 1].text += "\n\n" + text
            } else {
                turns.append((entry.role.rawValue, text))
            }
        }
        while turns.first?.role == "assistant" { turns.removeFirst() }
        return turns.map { ["role": $0.role, "content": $0.text] }
    }

    /// Claude Code takes a single prompt, so the conversation is written out as a transcript.
    private func transcriptPrompt() -> String {
        let lines = apiMessages().map { turn -> String in
            let speaker = turn["role"] as? String == "assistant" ? "Coach" : "Writer"
            return "\(speaker): \(turn["content"] as? String ?? "")"
        }
        return "Conversation so far (Writer is the person writing, Coach is you):\n\n"
            + lines.joined(separator: "\n\n")
            + "\n\nReply as the Coach to the Writer's last message."
    }

    // MARK: Prompt

    private func systemPrompt() -> String {
        let planning = settings.coachBackend == .api ? Self.toolPlanning : Self.structuredPlanning
        return Self.instructions.replacingOccurrences(of: "{PLAN_DELIVERY}", with: planning)
            + "\n\n<context>\n" + context() + "\n</context>"
    }

    private static let toolPlanning = """
    Then call the propose_plan tool with a realistic plan. Express targets in words, or in paragraphs if the \
    writer thinks in paragraphs. Milestones are cumulative totals. Don't also restate the plan in prose; the \
    app shows it as a card with Approve and Request changes buttons. If they ask for changes, call \
    propose_plan again with the revised plan. Use the propose_plan tool only for proposing or revising a plan.
    """

    private static let structuredPlanning = """
    Your reply is JSON: what you say to the writer goes in "message". When you propose a plan, put it in \
    "plan" and keep "message" to one short sentence introducing it; leave "plan" out otherwise. Express \
    targets in words, or in paragraphs if the writer thinks in paragraphs. Milestones are cumulative totals. \
    Don't restate the plan in "message"; the app shows it as a card with Approve and Request changes \
    buttons. If they ask for changes, send the revised plan in "plan" again.
    """

    private static let instructions = """
    You are the writing coach inside LaserFocus, a distraction-free Markdown writing app for macOS. \
    You live in a narrow panel beside the writer's document, so keep messages short.

    Planning: when the writer asks for a plan or wants to change one, interview them briefly. \
    Ask one question at a time, four or five at most in total: what they are writing and for whom, \
    how long it should be, the deadline, and when and how often they can write. {PLAN_DELIVERY}

    Coaching: once a plan is approved, help the writer keep to it. Remind them of today's goal, \
    encourage them when they are stuck, and celebrate progress. Be specific to their project and the \
    numbers in the context. When they are stuck on a word or sentence and the current paragraph is \
    provided, offer two or three concrete alternatives or a sentence starter, but never write the piece \
    for them. Being behind is a small next step, never a reason for guilt.

    Style: warm, direct and brief. Plain text only, no Markdown formatting. One to three sentences for \
    reminders and nudges; a little longer only when answering a question.

    Messages in square brackets starting with "LaserFocus:" are automatic events from the app, not words \
    the writer typed. Respond to them by speaking directly to the writer.
    """

    private func context() -> String {
        let text = textProvider()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var lines = [
            "Today is \(formatter.string(from: Date())).",
            "Document: \"\(titleProvider())\" — \(TextStats.words(in: text)) words, \(TextStats.paragraphs(in: text)) paragraphs.",
        ]
        if let plan = store.data.plan {
            lines.append("Approved plan:\n" + plan.description)
            if let status = status() { lines.append("Progress: " + status.summary) }
        } else {
            lines.append("No approved plan yet.")
        }
        if let pending = store.data.pendingPlan {
            lines.append("Proposal awaiting the writer's decision:\n" + pending.description)
        }
        if settings.coachSharesText {
            let ns = text as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: min(caretProvider(), ns.length), length: 0))
            let current = ns.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty {
                lines.append("Paragraph the writer is working on:\n\"\(String(current.prefix(1500)))\"")
            }
            if store.data.plan == nil && !text.isEmpty {
                lines.append("Opening of the document:\n\"\(String(text.prefix(1500)))\"")
            }
        } else {
            lines.append("The writer has chosen not to share their text with the coach.")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Reply format for Claude Code: a message, plus a plan when one is proposed.
    private static var replySchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["message"],
            "properties": [
                "message": ["type": "string", "description": "What the coach says to the writer."],
                "plan": proposePlanTool["input_schema"]!,
            ],
        ]
    }

    private static let proposePlanTool: [String: Any] = [
        "name": "propose_plan",
        "description": "Show the writer a writing plan as a card they can approve or ask to change. Call this after the planning interview, and again whenever the writer asks for changes.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "summary", "unit", "total_target", "daily_target", "start_date", "deadline",
                         "writing_days", "cadence", "milestones"],
            "properties": [
                "title": ["type": "string", "description": "Short name of the writing project."],
                "summary": ["type": "string", "description": "Two or three sentences explaining the plan and why it fits the writer."],
                "unit": ["type": "string", "enum": ["words", "paragraphs"], "description": "Unit for all targets."],
                "total_target": ["type": "integer", "description": "Total length to reach by the deadline, in the unit."],
                "daily_target": ["type": "integer", "description": "Amount to write on each writing day, in the unit."],
                "start_date": ["type": "string", "description": "First day of the plan, YYYY-MM-DD."],
                "deadline": ["type": "string", "description": "Last day of the plan, YYYY-MM-DD."],
                "writing_days": [
                    "type": "array",
                    "description": "Days of the week the writer will write.",
                    "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]],
                ],
                "cadence": ["type": "string", "description": "The rhythm in plain words, e.g. \"One paragraph every weekday morning\"."],
                "milestones": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["title", "due", "target"],
                        "properties": [
                            "title": ["type": "string"],
                            "due": ["type": "string", "description": "YYYY-MM-DD"],
                            "target": ["type": "integer", "description": "Cumulative total in the unit by this date."],
                        ],
                    ],
                ],
            ],
        ],
    ]

    // MARK: Plan status

    func status(on date: Date = Date()) -> PlanStatus? {
        guard let plan = store.data.plan else { return nil }
        let current = count(in: textProvider(), unit: plan.unit)
        let today = Self.dayKey(date)
        let baseline = store.data.baseline ?? current

        // Count at the start of today: the last recorded day before today, else the baseline.
        let earlier = store.data.progress.filter { $0.key < today }.max { $0.key < $1.key }
        let startOfToday = earlier?.value ?? baseline

        let calendar = Calendar.current
        let start = [Self.date(plan.startDate), Self.date(store.data.approvedOn ?? "")].compactMap { $0 }.max()
            ?? calendar.startOfDay(for: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))!
        let pastDays = writingDays(plan, from: start, through: yesterday)
        let expectedByYesterday = min(plan.totalTarget, baseline + plan.dailyTarget * pastDays)
        let isWritingDay = writingDays(plan, from: calendar.startOfDay(for: date), through: calendar.startOfDay(for: date)) == 1

        let deadline = Self.date(plan.deadline) ?? date
        let daysLeft = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: deadline).day ?? 0)
        let nextMilestone = plan.milestones.filter { $0.due >= today && $0.target > current }.min { $0.due < $1.due }

        return PlanStatus(unit: plan.unit,
                          current: current,
                          doneToday: max(0, current - startOfToday),
                          todayGoal: isWritingDay ? plan.dailyTarget : 0,
                          behind: max(0, expectedByYesterday - startOfToday),
                          totalTarget: plan.totalTarget,
                          daysLeft: daysLeft,
                          nextMilestone: nextMilestone)
    }

    private func localReminder(_ status: PlanStatus) -> String {
        var message = "Welcome back! "
        if status.todayGoal > 0 {
            message += "Today's goal: \(status.todayGoal) \(status.unit)."
        } else {
            message += "No writing planned today — a few \(status.unit) would put you ahead."
        }
        if status.behind > 0 {
            message += " You're \(status.behind) \(status.unit) behind; one focused session closes the gap."
        }
        return message
    }

    private func count(in text: String, unit: String) -> Int {
        unit == "paragraphs" ? TextStats.paragraphs(in: text) : TextStats.words(in: text)
    }

    /// Number of planned writing days between two days, inclusive.
    private func writingDays(_ plan: WritingPlan, from start: Date, through end: Date) -> Int {
        let calendar = Calendar.current
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var day = calendar.startOfDay(for: start)
        var count = 0
        while day <= end {
            let name = names[calendar.component(.weekday, from: day) - 1]
            if plan.writingDays.isEmpty || plan.writingDays.contains(name) { count += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return count
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(_ key: String) -> Date? { dayFormatter.date(from: key) }
}
