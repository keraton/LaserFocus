import Foundation

struct Milestone: Codable {
    var title: String
    var due: String          // yyyy-MM-dd
    var target: Int          // cumulative count in the plan's unit
}

/// A writing plan proposed by the coach (Claude) and approved by the writer.
/// Field names match the `propose_plan` tool's input schema.
struct WritingPlan: Codable {
    var id: String
    var title: String
    var summary: String
    var unit: String         // "words" or "paragraphs"
    var totalTarget: Int
    var dailyTarget: Int
    var startDate: String    // yyyy-MM-dd
    var deadline: String     // yyyy-MM-dd
    var writingDays: [String] // "mon"..."sun"; empty means every day
    var cadence: String
    var milestones: [Milestone]

    enum CodingKeys: String, CodingKey {
        case id, title, summary, unit, cadence, milestones, deadline
        case totalTarget = "total_target"
        case dailyTarget = "daily_target"
        case startDate = "start_date"
        case writingDays = "writing_days"
    }

    /// Builds a plan from the `propose_plan` tool input.
    static func fromToolInput(_ input: [String: Any]) -> WritingPlan? {
        var dict = input
        dict["id"] = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(WritingPlan.self, from: data)
    }

    /// Plain-text description, used when the plan is replayed to Claude.
    var description: String {
        var lines = [
            "Title: \(title)",
            "Summary: \(summary)",
            "Rhythm: \(cadence)",
            "Target: \(totalTarget) \(unit) by \(deadline), starting \(startDate)",
            "Daily target: \(dailyTarget) \(unit) on \(writingDays.isEmpty ? "every day" : writingDays.joined(separator: ", "))",
        ]
        for milestone in milestones {
            lines.append("Milestone: \(milestone.title) — \(milestone.target) \(unit) by \(milestone.due)")
        }
        return lines.joined(separator: "\n")
    }
}

struct ChatEntry: Codable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID().uuidString
    var role: Role
    var text: String
    /// Automatic app events sent to Claude but not shown in the chat.
    var hidden = false
    /// Set when this entry is a plan proposal card.
    var plan: WritingPlan?
    var date = Date()

    init(role: Role, text: String, hidden: Bool = false, plan: WritingPlan? = nil) {
        self.role = role
        self.text = text
        self.hidden = hidden
        self.plan = plan
    }
}

/// Everything the coach remembers about one document.
struct CoachData: Codable {
    var plan: WritingPlan?
    var pendingPlan: WritingPlan?
    /// Day the plan was approved and the document's count at that moment.
    var approvedOn: String?
    var baseline: Int?
    /// Count (in the plan's unit) at the last update of each day, keyed by yyyy-MM-dd.
    var progress: [String: Int] = [:]
    var celebratedOn: String?
    var chat: [ChatEntry] = []
}

extension Notification.Name {
    /// Posted (object: the store) when the coach's plan, progress or chat changes.
    static let coachChanged = Notification.Name("LaserFocusCoachChanged")
}

/// The coach's per-document memory, saved in a `HiddenBlock` at the end of the file so the
/// plan and the conversation come back every time the document is opened.
final class CoachStore {
    private(set) var data = CoachData()
    /// Called when the writer-visible state changes, so the document can be marked edited.
    var onUserChange: (() -> Void)?

    private static let maxChatEntries = 80

    func update(markEdited: Bool = true, _ change: (inout CoachData) -> Void) {
        change(&data)
        if data.chat.count > Self.maxChatEntries {
            data.chat.removeFirst(data.chat.count - Self.maxChatEntries)
        }
        if markEdited { onUserChange?() }
        NotificationCenter.default.post(name: .coachChanged, object: self)
    }

    func load(fromFile fileText: String) -> String {
        let (body, json) = HiddenBlock.extract("coach", from: fileText)
        data = json.flatMap { try? Self.decoder.decode(CoachData.self, from: Data($0.utf8)) } ?? CoachData()
        NotificationCenter.default.post(name: .coachChanged, object: self)
        return body
    }

    func fileText(body: String) -> String {
        let isEmpty = data.plan == nil && data.pendingPlan == nil && data.chat.isEmpty
        var shell = data
        shell.chat = []
        guard !isEmpty, let contents = HiddenBlock.json(data, emptied: shell, key: "chat", elements: data.chat,
                                                         encoder: Self.encoder) else { return body }
        return HiddenBlock.append("coach", contents: contents, to: body)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
