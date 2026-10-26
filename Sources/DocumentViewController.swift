import AppKit

/// Window content: the optional sidebar (outline / notes) on the left, the editor in the middle
/// and the writing coach on the right.
final class DocumentViewController: NSSplitViewController, NSMenuItemValidation {
    let editor: EditorViewController
    private let annotations: AnnotationStore
    private let sidebar: SidebarViewController
    private let settings = Settings.shared
    private var sidebarItem: NSSplitViewItem!
    private let coach: WritingCoach
    private let coachPanel: CoachViewController
    private var coachItem: NSSplitViewItem!

    init(editor: EditorViewController, annotations: AnnotationStore, coachStore: CoachStore) {
        self.editor = editor
        self.annotations = annotations
        sidebar = SidebarViewController(store: annotations)
        coach = WritingCoach(store: coachStore)
        coachPanel = CoachViewController(coach: coach)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        coach.stop()
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

        coachItem = NSSplitViewItem(viewController: coachPanel)
        coachItem.canCollapse = true
        coachItem.minimumThickness = 240
        coachItem.maximumThickness = 460
        coachItem.holdingPriority = NSLayoutConstraint.Priority(260)
        coachItem.isCollapsed = !settings.showCoach
        addSplitViewItem(coachItem)

        coach.textProvider = { [weak self] in self?.editor.text ?? "" }
        coach.caretProvider = { [weak self] in self?.editor.caretLocation ?? 0 }
        coach.titleProvider = { [weak self] in self?.documentTitle() ?? "Untitled" }
        coach.isWindowActive = { [weak self] in NSApp.isActive && (self?.view.window?.isKeyWindow ?? false) }
        coach.onNudge = { [weak self] in self?.setCoachVisible(true) }
        editor.onEdit = { [weak self] inserted, deleted in self?.coach.recordEdit(inserted: inserted, deleted: deleted) }

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

    override func viewDidAppear() {
        super.viewDidAppear()
        coach.start()
    }

    private func scheduleOutlineRefresh() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshOutline), object: nil)
        perform(#selector(refreshOutline), with: nil, afterDelay: 0.3)
    }

    @objc private func refreshOutline() {
        coach.textDidChange()
        guard settings.showSidebar else { return }
        sidebar.outline.update(text: editor.text, caret: editor.caretLocation)
    }

    private func documentTitle() -> String {
        if let heading = editor.text.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) {
            return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return view.window?.title ?? "Untitled"
    }

    // MARK: Coach

    private func setCoachVisible(_ visible: Bool) {
        guard coachItem.isCollapsed == visible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            coachItem.animator().isCollapsed = !visible
        }, completionHandler: nil)
    }

    /// Shows or hides this window's coach; new windows follow the last choice.
    @objc func toggleCoach(_ sender: Any?) {
        let visible = coachItem.isCollapsed
        setCoachVisible(visible)
        settings.showCoach = visible
    }

    @objc func planWriting(_ sender: Any?) {
        setCoachVisible(true)
        coachPanel.planWriting()
    }

    @objc func messageCoach(_ sender: Any?) {
        setCoachVisible(true)
        coachPanel.focusInput()
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
        if item.action == #selector(toggleCoach(_:)) {
            item.state = coachItem.isCollapsed ? .off : .on
        }
        return true
    }
}
