import AppKit

/// Sidebar tab for the writing outline: the points the writer means to cover, each with its
/// status, and a button that asks Claude which ones the text already covers.
///
/// Editing works like a list: Return adds a point below, Tab / Shift-Tab indent and outdent,
/// Delete in an empty point removes it. Clicking a status circle sets it by hand.
final class WritingOutlineViewController: NSViewController, NSTextFieldDelegate {
    /// Asks the document to run a check (it knows the text).
    var onCheck: (() -> Void)?
    /// Jumps to a quote from the text.
    var onReveal: ((String) -> Void)?
    /// The current word count, to tell whether the text changed since the last check.
    var wordCountProvider: () -> Int = { 0 }

    private let store: WritingOutlineStore
    private let checker: OutlineChecker
    private let settings = Settings.shared

    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let checkButton = NSButton(title: "Check with Claude", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let checkedLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "Write down what you mean to say, one point per line, before or while you write. Claude can then check which points your text already covers.")
    private let addField = NSTextField()
    private var rows: [OutlineRow] = []

    init(store: WritingOutlineStore, checker: OutlineChecker) {
        self.store = store
        self.checker = checker
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        progressLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.controlSize = .small
        progressBar.minValue = 0

        checkButton.target = self
        checkButton.action = #selector(checkClicked)
        checkButton.bezelStyle = .rounded
        checkButton.controlSize = .small
        checkButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        checkButton.toolTip = "Sends the outline and the whole text to Claude (⌃⌘C)"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        checkedLabel.font = NSFont.systemFont(ofSize: 10)
        checkedLabel.lineBreakMode = .byTruncatingTail
        checkedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        // Long summaries would push the points out of view; the full text is in the tooltip.
        summaryLabel.maximumNumberOfLines = 4
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.cell?.truncatesLastVisibleLine = true
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.isSelectable = true
        emptyLabel.font = NSFont.systemFont(ofSize: 12)

        let checkRow = NSStackView(views: [checkButton, spinner])
        checkRow.spacing = 6
        let header = NSStackView(views: [progressLabel, progressBar, checkRow, checkedLabel, summaryLabel, errorLabel, emptyLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setCustomSpacing(2, after: checkRow)
        for view in [progressBar, checkedLabel, summaryLabel, errorLabel, emptyLabel] as [NSView] {
            view.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = OutlineFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = document

        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.placeholderString = "Add a point…"
        addField.font = NSFont.systemFont(ofSize: 13)
        addField.bezelStyle = .roundedBezel
        addField.target = self
        addField.action = #selector(addFromField)

        [header, scrollView, addField].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addField.topAnchor, constant: -8),
            addField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            addField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            addField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = root

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reload), name: .writingOutlineChanged, object: store)
        center.addObserver(self, selector: #selector(reload), name: .settingsChanged, object: nil)
        center.addObserver(self, selector: #selector(updateHeader), name: .outlineCheckChanged, object: checker)
        reload()
    }

    // MARK: Header

    /// Refreshes "checked … ago" and whether the text changed since; called as the text changes.
    @objc func updateHeader() {
        let palette = settings.palette
        let points = store.points
        let done = store.doneCount
        let partial = points.filter { $0.status == .partial }.count
        progressLabel.textColor = palette.text
        progressLabel.stringValue = points.isEmpty ? "Writing outline"
            : "\(done) of \(points.count) written" + (partial > 0 ? ", \(partial) in progress" : "")
        progressBar.isHidden = points.isEmpty
        progressBar.maxValue = Double(max(points.count, 1))
        progressBar.doubleValue = Double(done) + Double(partial) * 0.5

        checkButton.isHidden = points.isEmpty
        checkButton.isEnabled = !checker.isChecking
        checker.isChecking ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        checkedLabel.textColor = palette.muted
        if checker.isChecking {
            checkedLabel.stringValue = "Claude is reading your text…"
        } else if let date = store.data.checkedAt {
            var line = "Checked " + Self.relative(date)
            if let words = store.data.checkedWordCount, words != wordCountProvider() { line += " · text changed" }
            checkedLabel.stringValue = line
        } else {
            checkedLabel.stringValue = ""
        }

        summaryLabel.textColor = palette.muted
        summaryLabel.stringValue = store.data.summary ?? ""
        summaryLabel.toolTip = store.data.summary
        summaryLabel.isHidden = points.isEmpty || (store.data.summary ?? "").isEmpty
        errorLabel.textColor = NSColor.systemRed
        errorLabel.stringValue = checker.lastError ?? ""
        errorLabel.isHidden = checker.lastError == nil
        emptyLabel.textColor = palette.muted
        emptyLabel.isHidden = !points.isEmpty
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if Calendar.current.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "at " + formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "on " + formatter.string(from: date)
    }

    @objc private func checkClicked() {
        view.window?.makeFirstResponder(nil)   // commit the point being edited
        onCheck?()
    }

    // MARK: Rows

    @objc func reload() {
        // Keep the caret in the point being edited.
        let editing = rows.first { $0.field.currentEditor() != nil }
        let caret = editing.flatMap { ($0.field.currentEditor() as? NSTextView)?.selectedRange() }
        rebuild(focusing: editing?.point, caret: caret)
    }

    private func rebuild(focusing point: OutlinePoint?, caret: NSRange?) {
        let palette = settings.palette
        rows.forEach { $0.removeFromSuperview() }
        rows = store.points.map { point in
            let row = OutlineRow(point: point, palette: palette)
            row.field.delegate = self
            row.onCycle = { [weak self] in self?.store.setStatus(point, point.status.next) }
            row.onDelete = { [weak self] in self?.store.remove(point) }
            row.onReveal = { [weak self] quote in self?.onReveal?(quote) }
            row.menuProvider = { [weak self] in self?.menu(for: point) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return row
        }
        updateHeader()
        guard let point = point, let row = rows.first(where: { $0.point === point }) else { return }
        view.window?.makeFirstResponder(row.field)
        if let editor = row.field.currentEditor() as? NSTextView {
            let length = (editor.string as NSString).length
            let range = caret.map { NSRange(location: min($0.location, length), length: 0) }
                ?? NSRange(location: length, length: 0)
            editor.setSelectedRange(range)
        }
        row.scrollToVisible(row.bounds)
    }

    private func focus(_ point: OutlinePoint, atEnd: Bool = true) {
        rebuild(focusing: point, caret: atEnd ? nil : NSRange(location: 0, length: 0))
    }

    @objc private func addFromField() {
        let text = addField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.insert(text: text, level: store.points.last?.level ?? 0)
        addField.stringValue = ""
        view.window?.makeFirstResponder(addField)
        rows.last?.scrollToVisible(rows.last!.bounds)
    }

    /// Starts typing a new point at the end, e.g. from the menu.
    func focusAddField() {
        view.window?.makeFirstResponder(addField)
    }

    private func menu(for point: OutlinePoint) -> NSMenu {
        let menu = NSMenu()
        for status in [CoverageStatus.done, .partial, .open] {
            let item = NSMenuItem(title: "Mark as \(status.title)", action: #selector(markFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (point, status)
            item.state = point.status == status ? .on : .off
            menu.addItem(item)
        }
        if point.setByWriter {
            let release = NSMenuItem(title: "Let Claude Decide", action: #selector(releaseFromMenu(_:)), keyEquivalent: "")
            release.target = self
            release.representedObject = point
            menu.addItem(release)
        }
        menu.addItem(.separator())
        let index = store.points.firstIndex { $0 === point } ?? 0
        for (title, offset, enabled) in [("Move Up", -1, index > 0), ("Move Down", 1, index < store.points.count - 1)] {
            let item = NSMenuItem(title: title, action: enabled ? #selector(moveFromMenu(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = (point, offset)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Point", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = point
        menu.addItem(delete)
        return menu
    }

    @objc private func markFromMenu(_ sender: NSMenuItem) {
        guard let (point, status) = sender.representedObject as? (OutlinePoint, CoverageStatus) else { return }
        store.setStatus(point, status)
    }

    @objc private func releaseFromMenu(_ sender: NSMenuItem) {
        guard let point = sender.representedObject as? OutlinePoint else { return }
        store.releaseStatus(point)
    }

    @objc private func moveFromMenu(_ sender: NSMenuItem) {
        guard let (point, offset) = sender.representedObject as? (OutlinePoint, Int) else { return }
        store.move(point, by: offset)
    }

    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        guard let point = sender.representedObject as? OutlinePoint else { return }
        store.remove(point)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }) else { return }
        store.updateText(row.point, to: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let row = rows.first(where: { $0.field === control }) else { return false }
        let point = row.point
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            store.updateText(point, to: textView.string)
            focus(store.insert(text: "", level: point.level, after: point))
        case #selector(NSResponder.insertTab(_:)):
            store.setLevel(point, point.level + 1)
        case #selector(NSResponder.insertBacktab(_:)):
            store.setLevel(point, point.level - 1)
        case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty:
            let index = store.points.firstIndex { $0 === point } ?? 0
            store.remove(point)
            if index > 0 { focus(store.points[index - 1]) } else { focusAddField() }
        case #selector(NSResponder.moveUp(_:)):
            guard let index = store.points.firstIndex(where: { $0 === point }), index > 0 else { return false }
            focus(store.points[index - 1])
        case #selector(NSResponder.moveDown(_:)):
            guard let index = store.points.firstIndex(where: { $0 === point }) else { return false }
            if index + 1 < store.points.count { focus(store.points[index + 1]) } else { focusAddField() }
        default:
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Points left empty when the writer moves on are removed.
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }),
              row.point.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let point = row.point
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.store.points.contains(where: { $0 === point }),
                  point.text.trimmingCharacters(in: .whitespaces).isEmpty,
                  self.rows.first(where: { $0.point === point })?.field.currentEditor() == nil else { return }
            self.store.remove(point)
        }
    }
}

private final class OutlineFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One outline point: status circle, editable text, delete button, and Claude's comment
/// with the quote that covers the point.
private final class OutlineRow: NSView {
    let point: OutlinePoint
    let field = WrappingTextField()
    var onCycle: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReveal: ((String) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    init(point: OutlinePoint, palette: Palette) {
        self.point = point
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let status = NSButton(title: "", target: nil, action: #selector(cycle))
        status.target = self
        status.isBordered = false
        status.translatesAutoresizingMaskIntoConstraints = false
        let symbol: String
        let color: NSColor
        switch point.status {
        case .open: symbol = "○"; color = palette.muted
        case .partial: symbol = "◐"; color = palette.annotation
        case .done: symbol = "●"; color = palette.object
        }
        status.attributedTitle = NSAttributedString(string: symbol, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: color,
        ])
        status.toolTip = point.status.title + (point.setByWriter ? " (set by you)" : "") + ". Click to change."

        field.translatesAutoresizingMaskIntoConstraints = false
        field.stringValue = point.text
        field.placeholderString = "New point"
        field.font = point.level == 0 ? NSFont.systemFont(ofSize: 13, weight: .medium) : NSFont.systemFont(ofSize: 13)
        field.textColor = point.status == .done ? palette.muted : palette.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let delete = NSButton(title: "✕", target: nil, action: #selector(deleteClicked))
        delete.target = self
        delete.isBordered = false
        delete.translatesAutoresizingMaskIntoConstraints = false
        delete.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: palette.muted.withAlphaComponent(0.6),
        ])
        delete.toolTip = "Delete point"

        let details = NSStackView()
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 2
        details.translatesAutoresizingMaskIntoConstraints = false
        if let comment = point.comment {
            let label = NSTextField(wrappingLabelWithString: comment)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = palette.muted
            details.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        if let evidence = point.evidence {
            let quote = NSButton(title: "", target: nil, action: #selector(revealClicked))
            quote.target = self
            quote.isBordered = false
            quote.alignment = .left
            quote.lineBreakMode = .byTruncatingTail
            quote.attributedTitle = NSAttributedString(string: "“\(evidence)”", attributes: [
                .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask),
                .foregroundColor: palette.accent,
            ])
            quote.toolTip = "Show this passage in the text"
            quote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            details.addArrangedSubview(quote)
            quote.widthAnchor.constraint(lessThanOrEqualTo: details.widthAnchor).isActive = true
        }

        [status, field, delete, details].forEach(addSubview)
        let indent = 10 + CGFloat(point.level) * 16
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            status.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            status.widthAnchor.constraint(equalToConstant: 18),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            field.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -2),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            delete.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            delete.widthAnchor.constraint(equalToConstant: 14),
            details.topAnchor.constraint(equalTo: field.bottomAnchor, constant: details.arrangedSubviews.isEmpty ? 0 : 2),
            details.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            details.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            details.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    @objc private func cycle() { onCycle?() }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func revealClicked() {
        if let evidence = point.evidence { onReveal?(evidence) }
    }
}
