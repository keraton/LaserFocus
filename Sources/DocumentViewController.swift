import AppKit

/// Window content: the optional sidebar (outline / notes) on the left, the editor in the middle
/// and the writing coach on the right.
final class DocumentViewController: NSSplitViewController, NSMenuItemValidation {
    let editor: EditorViewController
    private let annotations: AnnotationStore
    private let writingOutline: WritingOutlineStore
    private let outlineChecker: OutlineChecker
    private let sidebar: SidebarViewController
    private let settings = Settings.shared
    private var sidebarItem: NSSplitViewItem!
    private let coach: WritingCoach
    private let coachPanel: CoachViewController
    private var coachItem: NSSplitViewItem!

    init(editor: EditorViewController, annotations: AnnotationStore, writingOutline: WritingOutlineStore,
         coachStore: CoachStore) {
        self.editor = editor
        self.annotations = annotations
        self.writingOutline = writingOutline
        outlineChecker = OutlineChecker(store: writingOutline)
        sidebar = SidebarViewController(store: annotations, writingOutline: writingOutline, checker: outlineChecker)
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
        editorItem.minimumThickness = EditorViewController.minimumWidth
        addSplitViewItem(editorItem)

        coachItem = NSSplitViewItem(viewController: coachPanel)
        coachItem.canCollapse = true
        coachItem.minimumThickness = 240
        coachItem.maximumThickness = 460
        coachItem.holdingPriority = NSLayoutConstraint.Priority(260)
        coachItem.isCollapsed = !settings.showCoach
        addSplitViewItem(coachItem)

        editor.syncStatus = { [weak self] in
            let url = (self?.view.window?.windowController?.document as? NSDocument)?.fileURL
            return SyncLibrary.shared.contains(url) ? SyncLibrary.shared.statusText : nil
        }
        coach.textProvider = { [weak self] in self?.editor.text ?? "" }
        coach.caretProvider = { [weak self] in self?.editor.caretLocation ?? 0 }
        coach.titleProvider = { [weak self] in self?.documentTitle() ?? "Untitled" }
        coach.isWindowActive = { [weak self] in NSApp.isActive && (self?.view.window?.isKeyWindow ?? false) }
        coach.onNudge = { [weak self] in self?.setCoachVisible(true) }
        coach.outlineProvider = { [weak self] in
            guard let store = self?.writingOutline, !store.points.isEmpty else { return nil }
            return store.promptText(includeIDs: false)
        }
        editor.onEdit = { [weak self] inserted, deleted in self?.coach.recordEdit(inserted: inserted, deleted: deleted) }

        sidebar.outline.onSelectHeading = { [weak self] location in
            self?.editor.reveal(range: NSRange(location: location, length: 0))
        }
        sidebar.notes.onReveal = { [weak self] annotation in
            self?.editor.reveal(range: annotation.range)
        }
        sidebar.writingOutline.onCheck = { [weak self] in self?.checkOutline(nil) }
        sidebar.writingOutline.onReveal = { [weak self] quote in self?.revealQuote(quote) }
        sidebar.writingOutline.wordCountProvider = { [weak self] in TextStats.words(in: self?.editor.text ?? "") }
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
        if !collapse {
            refreshOutline()
            makeRoom(for: sidebarItem)
        }
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
        switch settings.sidebarTab {
        case .outline: sidebar.outline.update(text: editor.text, caret: editor.caretLocation)
        case .writingOutline: sidebar.writingOutline.updateHeader()
        case .notes: break
        }
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
        if visible { makeRoom(for: coachItem) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            coachItem.animator().isCollapsed = !visible
        }, completionHandler: nil)
    }

    /// Widens the window before a panel opens when the editor would otherwise get narrower
    /// than its text column, so lines keep the same length.
    private func makeRoom(for item: NSSplitViewItem) {
        guard let window = view.window, item.isCollapsed else { return }
        let panel = max(item.minimumThickness, item.viewController.view.frame.width) + splitView.dividerThickness
        let shortfall = EditorViewController.minimumWidth - (editor.view.frame.width - panel)
        guard shortfall > 0 else { return }
        var frame = window.frame
        frame.size.width += shortfall
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        }
        window.setFrame(frame, display: true)
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

    // MARK: Writing outline

    /// Shows the writing outline and asks Claude which points the text covers.
    @objc func checkOutline(_ sender: Any?) {
        settings.sidebarTab = .writingOutline
        settings.showSidebar = true
        outlineChecker.check(text: editor.text, title: documentTitle())
    }

    @objc func addOutlinePoint(_ sender: Any?) {
        settings.sidebarTab = .writingOutline
        settings.showSidebar = true
        DispatchQueue.main.async { [weak self] in self?.sidebar.writingOutline.focusAddField() }
    }

    /// Selects a passage Claude quoted. Quotes may differ slightly from the text (case, spacing),
    /// so looser searches follow an exact one.
    private func revealQuote(_ quote: String) {
        let ns = editor.text as NSString
        var found = ns.range(of: quote)
        if found.location == NSNotFound { found = ns.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive]) }
        if found.location == NSNotFound {
            // Try a shorter start of the quote, then its first few words.
            let words = quote.split(separator: " ")
            for count in [8, 5, 3] where words.count > count {
                found = ns.range(of: words.prefix(count).joined(separator: " "), options: [.caseInsensitive])
                if found.location != NSNotFound { break }
            }
        }
        guard found.location != NSNotFound else {
            NSSound.beep()
            return
        }
        editor.reveal(range: found)
        editor.textView.setSelectedRange(found)
        view.window?.makeFirstResponder(editor.textView)
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
        if item.action == #selector(checkOutline(_:)) {
            return !outlineChecker.isChecking && !writingOutline.points.isEmpty
        }
        if item.action == #selector(addAnnotation(_:)) {
            return !editor.textView.string.isEmpty
        }
        if item.action == #selector(toggleCoach(_:)) {
            item.state = coachItem.isCollapsed ? .off : .on
        }
        return true
    }
}
