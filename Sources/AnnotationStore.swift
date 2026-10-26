import Foundation

/// A note attached to a span of the document's text.
final class Annotation: Codable {
    let id: String
    var location: Int
    var length: Int
    /// The annotated text, used to re-find the span if the file was edited elsewhere.
    var anchor: String
    var note: String

    var range: NSRange { NSRange(location: location, length: length) }

    init(range: NSRange, anchor: String, note: String = "") {
        id = UUID().uuidString
        location = range.location
        length = range.length
        self.anchor = anchor
        self.note = note
    }
}

extension Notification.Name {
    /// Posted (object: the store) when annotations are added, removed or reloaded.
    static let annotationsChanged = Notification.Name("LaserFocusAnnotationsChanged")
}

/// Annotations for one document. They are kept out of the editable text and saved in a
/// hidden HTML comment block at the end of the Markdown file, so they travel with it
/// and are invisible in any Markdown viewer.
final class AnnotationStore {
    private(set) var items: [Annotation] = []
    /// Called whenever the user changes annotations, so the document can be marked edited.
    var onUserChange: (() -> Void)?

    private static let blockStart = "<!-- laserfocus:annotations"
    private static let blockRegex = try! NSRegularExpression(
        pattern: "\\n<!-- laserfocus:annotations\\n([\\s\\S]*?)\\n-->\\n?\\z")

    // MARK: Editing

    @discardableResult
    func add(range: NSRange, in text: NSString) -> Annotation {
        let annotation = Annotation(range: range, anchor: text.substring(with: range))
        items.append(annotation)
        sort()
        changed()
        return annotation
    }

    func remove(_ annotation: Annotation) {
        items.removeAll { $0 === annotation }
        changed()
    }

    func updateNote(_ annotation: Annotation, to note: String) {
        guard annotation.note != note else { return }
        annotation.note = note
        onUserChange?()
    }

    /// The innermost annotation covering `location`, if any.
    func annotation(at location: Int) -> Annotation? {
        items.filter { $0.length > 0 && location >= $0.location && location <= NSMaxRange($0.range) }
            .min { $0.length < $1.length }
    }

    /// Keeps anchors attached to their text while the document is edited.
    /// `editedRange` is in the new text; `delta` is the change in length.
    func adjust(editedRange: NSRange, delta: Int) {
        guard !items.isEmpty else { return }
        let oldStart = editedRange.location
        let oldEnd = editedRange.location + editedRange.length - delta
        let newEditEnd = NSMaxRange(editedRange)

        for annotation in items {
            let start = annotation.location
            let end = NSMaxRange(annotation.range)
            // Text typed right before an anchor pushes it along; text typed right after stays outside.
            let newStart = start < oldStart ? start : (start >= oldEnd ? start + delta : newEditEnd)
            let newEnd = end <= oldStart ? end : (end >= oldEnd ? end + delta : oldStart)
            annotation.location = newStart
            annotation.length = max(0, newEnd - newStart)
        }
    }

    private func sort() {
        items.sort { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
    }

    private func changed() {
        onUserChange?()
        NotificationCenter.default.post(name: .annotationsChanged, object: self)
    }

    // MARK: File format

    /// Splits a file into its visible text and loads the annotations stored in it.
    func load(fromFile fileText: String) -> String {
        let ns = fileText as NSString
        guard let match = Self.blockRegex.firstMatch(in: fileText, range: NSRange(location: 0, length: ns.length)) else {
            items = []
            NotificationCenter.default.post(name: .annotationsChanged, object: self)
            return fileText
        }
        let body = ns.substring(to: match.range.location)
        let json = ns.substring(with: match.range(at: 1))
        let decoded = (try? JSONDecoder().decode([Annotation].self, from: Data(json.utf8))) ?? []
        items = decoded.map { reattach($0, in: body as NSString) }
        sort()
        NotificationCenter.default.post(name: .annotationsChanged, object: self)
        return body
    }

    /// The text to write to disk: the visible text plus the hidden annotation block.
    func fileText(body: String) -> String {
        let ns = body as NSString
        for annotation in items where annotation.length > 0 && NSMaxRange(annotation.range) <= ns.length {
            annotation.anchor = ns.substring(with: annotation.range)
        }
        guard !items.isEmpty else { return body }

        let encoder = JSONEncoder()
        if #available(macOS 10.13, *) { encoder.outputFormatting = [.sortedKeys] }
        let lines = items.compactMap { item -> String? in
            guard let data = try? encoder.encode(item), let line = String(data: data, encoding: .utf8) else { return nil }
            // "-->" would end the HTML comment early; it can only appear inside JSON strings.
            return line.replacingOccurrences(of: "-->", with: "--\\u003e")
        }
        let separator = body.hasSuffix("\n") ? "" : "\n"
        return body + separator + "\n" + Self.blockStart + "\n[\n" + lines.joined(separator: ",\n") + "\n]\n-->\n"
    }

    /// Makes sure a loaded annotation still points at its anchor text, searching for the
    /// nearest copy if the file was changed by another app.
    private func reattach(_ annotation: Annotation, in body: NSString) -> Annotation {
        let range = annotation.range
        if NSMaxRange(range) <= body.length && body.substring(with: range) == annotation.anchor {
            return annotation
        }
        var best: NSRange?
        var search = NSRange(location: 0, length: body.length)
        while !annotation.anchor.isEmpty {
            let found = body.range(of: annotation.anchor, options: [], range: search)
            if found.location == NSNotFound { break }
            if best == nil || abs(found.location - range.location) < abs(best!.location - range.location) {
                best = found
            }
            search = NSRange(location: found.location + 1, length: body.length - found.location - 1)
        }
        if let best = best {
            annotation.location = best.location
            annotation.length = best.length
        } else {
            annotation.location = min(range.location, body.length)
            annotation.length = 0
        }
        return annotation
    }
}
