import AppKit

/// Window content: the optional outline sidebar on the left and the editor on the right.
final class DocumentViewController: NSSplitViewController {
    let editor: EditorViewController
    private let outline = OutlineViewController()
    private let settings = Settings.shared
    private var outlineItem: NSSplitViewItem!

    init(editor: EditorViewController) {
        self.editor = editor
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

        outlineItem = NSSplitViewItem(viewController: outline)
        outlineItem.canCollapse = true
        outlineItem.minimumThickness = 160
        outlineItem.maximumThickness = 400
        outlineItem.holdingPriority = NSLayoutConstraint.Priority(260)
        outlineItem.isCollapsed = !settings.showOutline
        addSplitViewItem(outlineItem)

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 320
        addSplitViewItem(editorItem)

        outline.onSelectHeading = { [weak self] location in self?.editor.reveal(location: location) }
        editor.onTextChange = { [weak self] in self?.scheduleOutlineRefresh() }
        editor.onCaretMove = { [weak self] caret in
            guard let self = self, !self.outlineItem.isCollapsed else { return }
            self.outline.highlightHeading(containing: caret)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .settingsChanged, object: nil)
        refreshOutline()
    }

    @objc private func settingsChanged() {
        let collapse = !settings.showOutline
        guard outlineItem.isCollapsed != collapse else { return }
        if !collapse { refreshOutline() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            outlineItem.animator().isCollapsed = collapse
        }, completionHandler: nil)
    }

    private func scheduleOutlineRefresh() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshOutline), object: nil)
        perform(#selector(refreshOutline), with: nil, afterDelay: 0.3)
    }

    @objc private func refreshOutline() {
        guard !outlineItem.isCollapsed || settings.showOutline else { return }
        outline.update(text: editor.text, caret: editor.caretLocation)
    }
}
