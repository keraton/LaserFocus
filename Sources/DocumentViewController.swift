import AppKit

/// Window content: the optional sidebar (outline / notes) on the left and the editor on the right.
final class DocumentViewController: NSSplitViewController, NSMenuItemValidation {
    let editor: EditorViewController
    private let annotations: AnnotationStore
    private let sidebar: SidebarViewController
    private let settings = Settings.shared
    private var sidebarItem: NSSplitViewItem!

    init(editor: EditorViewController, annotations: AnnotationStore) {
        self.editor = editor
        self.annotations = annotations
        sidebar = SidebarViewController(store: annotations)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.autosaveName = "LaserFocusSplit"

        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.isCollapsed = !settings.showSidebar
        addSplitViewItem(sidebarItem)

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 320
        addSplitViewItem(editorItem)

        sidebar.outline.onSelectHeading = { [weak self] location in
            self?.editor.reveal(range: NSRange(location: location, length: 0))
        }
        sidebar.notes.onReveal = { [weak self] annotation in
            self?.editor.reveal(range: annotation.range)
        }
        editor.onTextChange = { [weak self] in self?.scheduleOutlineRefresh() }
        editor.onCaretMove = { [weak self] caret in
            guard let self = self, !self.sidebarItem.isCollapsed else { return }
            self.sidebar.outline.highlightHeading(containing: caret)
            self.sidebar.notes.highlight(self.annotations.annotation(at: caret))
        }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .settingsChanged, object: nil)
        refreshOutline()
    }

    @objc private func settingsChanged() {
        let collapse = !settings.showSidebar
        guard sidebarItem.isCollapsed != collapse else { return }
        if !collapse { refreshOutline() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed = collapse
        }, completionHandler: nil)
    }

    private func scheduleOutlineRefresh() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshOutline), object: nil)
        perform(#selector(refreshOutline), with: nil, afterDelay: 0.3)
    }

    @objc private func refreshOutline() {
        guard settings.showSidebar else { return }
        sidebar.outline.update(text: editor.text, caret: editor.caretLocation)
    }

    // MARK: Annotations

    /// Annotates the selected text, or the sentence around the caret when nothing is selected.
    @objc func addAnnotation(_ sender: Any?) {
        let textView = editor.textView
        let ns = textView.string as NSString
        var range = textView.selectedRange()
        if range.length == 0 {
            let paragraph = ns.paragraphRange(for: range)
            ns.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, sentence, enclosing, stop in
                if sentence.location <= range.location && range.location <= NSMaxRange(enclosing) {
                    range = sentence
                    stop.pointee = true
                }
            }
        }
        guard range.length > 0 else {
            NSSound.beep()
            return
        }
        let annotation = annotations.add(range: range, in: ns)
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        settings.sidebarTab = .notes
        settings.showSidebar = true
        DispatchQueue.main.async { [weak self] in self?.sidebar.notes.beginEditing(annotation) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(addAnnotation(_:)) {
            return !editor.textView.string.isEmpty
        }
        return true
    }
}
