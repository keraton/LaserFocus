import Foundation

/// How far the text has got with one point of the writing outline.
enum CoverageStatus: String, Codable {
    case open, partial, done

    var next: CoverageStatus {
        switch self {
        case .open: return .partial
        case .partial: return .done
        case .done: return .open
        }
    }

    var title: String {
        switch self {
        case .open: return "Not written yet"
        case .partial: return "Partly written"
        case .done: return "Written"
        }
    }
}

/// One point of the writer's outline: what they meant to say, before writing it.
final class OutlinePoint: Codable {
    let id: String
    var text: String
    /// Indentation, 0 to 2.
    var level: Int
    var status: CoverageStatus
    /// True when the writer set the status themselves; Claude's checks then leave it alone.
    var setByWriter: Bool
    /// A short quote from the document where the point is covered, as found by Claude.
    var evidence: String?
    /// Claude's one-line comment, e.g. what is still missing.
    var comment: String?

    init(text: String, level: Int = 0) {
        id = UUID().uuidString
        self.text = text
        self.level = level
        status = .open
        setByWriter = false
    }

    static let maxLevel = 2
}

struct OutlineData: Codable {
    var points: [OutlinePoint] = []
    /// When Claude last checked the outline against the text, and its summary.
    var checkedAt: Date?
    var summary: String?
    /// Word count of the text at the last check, to tell whether it has changed since.
    var checkedWordCount: Int?
}

extension Notification.Name {
    /// Posted (object: the store) when points are added, removed, moved or re-checked.
    /// Typing inside a point doesn't post it.
    static let writingOutlineChanged = Notification.Name("LaserFocusWritingOutlineChanged")
}

/// The writing outline of one document, saved in a hidden block of the Markdown file.
final class WritingOutlineStore {
    private(set) var data = OutlineData()
    var points: [OutlinePoint] { data.points }
    /// Called whenever the user changes the outline, so the document can be marked edited.
    var onUserChange: (() -> Void)?

    var doneCount: Int { points.filter { $0.status == .done }.count }

    // MARK: Editing

    @discardableResult
    func insert(text: String, level: Int = 0, after point: OutlinePoint? = nil) -> OutlinePoint {
        let new = OutlinePoint(text: text, level: max(0, min(OutlinePoint.maxLevel, level)))
        if let point = point, let index = points.firstIndex(where: { $0 === point }) {
            data.points.insert(new, at: index + 1)
        } else {
            data.points.append(new)
        }
        changed()
        return new
    }

    func remove(_ point: OutlinePoint) {
        data.points.removeAll { $0 === point }
        changed()
    }

    func updateText(_ point: OutlinePoint, to text: String) {
        guard point.text != text else { return }
        point.text = text
        onUserChange?()
    }

    func setLevel(_ point: OutlinePoint, _ level: Int) {
        let level = max(0, min(OutlinePoint.maxLevel, level))
        guard point.level != level else { return }
        point.level = level
        changed()
    }

    func move(_ point: OutlinePoint, by offset: Int) {
        guard let index = points.firstIndex(where: { $0 === point }) else { return }
        let target = index + offset
        guard points.indices.contains(target) else { return }
        data.points.swapAt(index, target)
        changed()
    }

    /// The writer's own verdict, which Claude's checks then respect.
    func setStatus(_ point: OutlinePoint, _ status: CoverageStatus) {
        point.status = status
        point.setByWriter = true
        changed()
    }

    /// Hands the point back to Claude: the next check decides its status.
    func releaseStatus(_ point: OutlinePoint) {
        point.setByWriter = false
        changed()
    }

    /// Applies Claude's verdicts, keyed by point id.
    func applyCheck(_ results: [String: (status: CoverageStatus, evidence: String?, comment: String?)],
                    summary: String?, wordCount: Int) {
        for point in points {
            guard let result = results[point.id] else { continue }
            if !point.setByWriter { point.status = result.status }
            point.evidence = result.evidence
            point.comment = result.comment
        }
        data.summary = summary
        data.checkedAt = Date()
        data.checkedWordCount = wordCount
        changed()
    }

    private func changed() {
        onUserChange?()
        NotificationCenter.default.post(name: .writingOutlineChanged, object: self)
    }

    // MARK: File format

    /// Splits a file into its remaining text and loads the outline stored in it.
    func load(fromFile fileText: String) -> String {
        let (body, json) = HiddenBlock.extract("outline", from: fileText)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        data = json.flatMap { try? decoder.decode(OutlineData.self, from: Data($0.utf8)) } ?? OutlineData()
        NotificationCenter.default.post(name: .writingOutlineChanged, object: self)
        return body
    }

    /// The text to write to disk: `body` plus the hidden outline block.
    func fileText(body: String) -> String {
        guard !points.isEmpty else { return body }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(data), let text = String(data: json, encoding: .utf8) else { return body }
        return HiddenBlock.append("outline", contents: text, to: body)
    }

    /// The outline as plain text for prompts: one point per line, indented, with its status.
    func promptText(includeIDs: Bool) -> String {
        points.map { point in
            let indent = String(repeating: "  ", count: point.level)
            let id = includeIDs ? "[\(point.id)] " : ""
            return "\(indent)- \(id)\(point.text) (\(point.status.title.lowercased()))"
        }.joined(separator: "\n")
    }
}
