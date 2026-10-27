import AppKit

/// Edit ▸ Spelling and Grammar ▸ Custom Dictionary…: the words the writer added, with
/// a field to add new ones and a button to remove the selected ones.
final class CustomDictionaryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = CustomDictionaryWindowController()

    private let dictionary = CustomDictionary.shared
    private let table = NSTableView()
    private let field = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Custom Dictionary"
        panel.minSize = NSSize(width: 280, height: 260)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildContent(in: panel)
        panel.center()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .customDictionaryChanged, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in panel: NSPanel) {
        let content = NSView()
        panel.contentView = content

        let intro = NSTextField(wrappingLabelWithString:
            "Words here are never marked as typos, in any language. Add words from the editor by right-clicking a word marked as misspelled.")
        intro.font = NSFont.systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor

        field.placeholderString = "New word"
        field.target = self
        field.action = #selector(addWord)
        addButton.target = self
        addButton.action = #selector(addWord)
        addButton.bezelStyle = .rounded

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        column.title = "Word"
        table.addTableColumn(column)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        removeButton.target = self
        removeButton.action = #selector(removeWords)
        removeButton.bezelStyle = .rounded
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        for view in [intro, field, addButton, scroll, removeButton, countLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            field.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            addButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            addButton.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),

            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: intro.trailingAnchor),

            removeButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            removeButton.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            removeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            countLabel.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
        ])
    }

    @objc private func reload() {
        table.reloadData()
        let count = dictionary.words.count
        countLabel.stringValue = count == 1 ? "1 word" : "\(count) words"
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    @objc private func addWord() {
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !word.contains(" ") else {
            NSSound.beep()
            return
        }
        dictionary.add(word)
        field.stringValue = ""
        if let row = dictionary.words.firstIndex(where: { $0.lowercased() == word.lowercased() }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    @objc private func removeWords() {
        let selected = table.selectedRowIndexes.map { dictionary.words[$0] }
        selected.forEach { dictionary.remove($0) }
        table.deselectAll(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { dictionary.words.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = id
            label.lineBreakMode = .byTruncatingTail
            return label
        }()
        cell.stringValue = dictionary.words[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}
