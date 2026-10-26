import AppKit

/// One Markdown heading and the headings nested under it.
final class HeadingNode {
    let title: String
    let level: Int
    let location: Int
    var children: [HeadingNode] = []

    init(title: String, level: Int, location: Int) {
        self.title = title
        self.level = level
        self.location = location
    }
}

/// Sidebar showing the document's heading hierarchy. Clicking a heading jumps to it,
/// and the heading containing the caret is highlighted as you write.
final class OutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelectHeading: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "No headings yet.\nStart a line with # to add one.")
    private let settings = Settings.shared
    private let styler = MarkdownStyler()
    private let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+(.*?)[ \\t#]*$",
                                                        options: [.anchorsMatchLines])
    private var roots: [HeadingNode] = []
    private var flat: [HeadingNode] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 700))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 12
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(headingClicked)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0

        root.wantsLayer = true
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
        ])
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: .settingsChanged, object: nil)
        applyTheme()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applyTheme() {
        let palette = settings.palette
        view.layer?.backgroundColor = palette.sidebar.cgColor
        emptyLabel.textColor = palette.muted
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    // MARK: Updating

    func update(text: String, caret: Int) {
        let ns = text as NSString
        let fences = styler.fencedBlocks(in: text)
        var newRoots: [HeadingNode] = []
        var newFlat: [HeadingNode] = []
        var stack: [HeadingNode] = []

        headingRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, !fences.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return }
            let title = ns.substring(with: m.range(at: 2))
            let node = HeadingNode(title: title.isEmpty ? "Untitled" : title,
                                   level: m.range(at: 1).length,
                                   location: m.range.location)
            while let last = stack.last, last.level >= node.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { newRoots.append(node) }
            stack.append(node)
            newFlat.append(node)
        }

        let changed = newFlat.map { "\($0.level)\($0.title)" } != flat.map { "\($0.level)\($0.title)" }
        roots = newRoots
        flat = newFlat
        if changed {
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        }
        emptyLabel.isHidden = !flat.isEmpty
        highlightHeading(containing: caret)
    }

    func highlightHeading(containing caret: Int) {
        guard let current = flat.last(where: { $0.location <= caret }) else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: current)
        guard row >= 0, outlineView.selectedRow != row else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? HeadingNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? HeadingNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? HeadingNode)?.children.isEmpty ?? true)
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? HeadingNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HeadingCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier)
        let palette = settings.palette
        cell.textField?.stringValue = node.title
        cell.textField?.font = node.level == 1 ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 12)
        cell.textField?.textColor = node.level <= 2 ? palette.text : palette.muted
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func headingClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? HeadingNode else { return }
        onSelectHeading?(node.location)
    }
}
