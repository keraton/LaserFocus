import AppKit

/// Hosts the writing surface: a centered text column, live Markdown styling,
/// the focus dimming, typewriter scrolling and a small status line.
final class EditorViewController: NSViewController, NSTextStorageDelegate, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    let textView: FocusTextView
    private let statusLabel = NSTextField(labelWithString: "")
    private let styler = MarkdownStyler()
    private let settings = Settings.shared
    private let maxColumnWidth: CGFloat = 720
    private var wordCount = 0

    /// Called after the text changes (for the outline sidebar).
    var onTextChange: (() -> Void)?
    /// Called with the caret location whenever the selection moves.
    var onCaretMove: ((Int) -> Void)?

    var caretLocation: Int { textView.selectedRange().location }

    init(text: String) {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = FocusTextView(frame: .zero, textContainer: container)
        super.init(nibName: nil, bundle: nil)
        storage.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            restyleAll()
            updateWordCount()
            onTextChange?()
        }
    }

    /// Moves the caret to `location` and scrolls that line near the top of the view.
    func reveal(location: Int) {
        let ns = textView.string as NSString
        let target = NSRange(location: min(location, ns.length), length: 0)
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(target)
        guard !settings.typewriter,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let y = rect.minY + textView.textContainerOrigin.y - 60
        let maxY = max(0, textView.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: View setup

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.delegate = self
        scrollView.documentView = textView

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingHead

        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySettings()
        updateWordCount()
        view.window?.makeFirstResponder(textView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInsets()
    }

    @objc private func settingsChanged() {
        applySettings()
    }

    @objc private func scrolled() {
        // Keep the ghost suggestion and dimming crisp while scrolling.
        textView.needsDisplay = true
    }

    private func applySettings() {
        let palette = settings.palette

        if let window = view.window {
            if #available(macOS 10.14, *) {
                window.appearance = NSAppearance(named: settings.isDark ? .darkAqua : .aqua)
            } else {
                window.appearance = NSAppearance(named: settings.isDark ? .vibrantDark : .aqua)
            }
            window.backgroundColor = palette.background
        }
        scrollView.backgroundColor = palette.background
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.caret
        textView.selectedTextAttributes = [.backgroundColor: palette.selection]
        textView.ghostColor = palette.ghost
        textView.autocompleteEnabled = settings.autocomplete
        if !settings.autocomplete { textView.clearSuggestion() }
        textView.font = settings.baseFont()
        textView.typingAttributes = [.font: settings.baseFont(), .foregroundColor: palette.text]

        updateInsets()
        restyleAll()
        updateStatus()
    }

    private func updateInsets() {
        let width = scrollView.contentSize.width
        let horizontal = max(32, (width - maxColumnWidth) / 2)
        let vertical = settings.typewriter ? scrollView.contentSize.height / 2 : 48
        let inset = NSSize(width: horizontal, height: vertical)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
            if settings.typewriter { centerCaret() }
        }
    }

    // MARK: Styling

    private func restyleAll() {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        styler.style(storage, range: NSRange(location: 0, length: storage.length), settings: settings)
        storage.endEditing()
        updateFocus()
    }

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let ns = textStorage.string as NSString
        var range = ns.paragraphRange(for: editedRange)
        // Small documents are cheap to restyle entirely; also needed when a code fence changes.
        if ns.length < 30_000 || ns.substring(with: range).contains("```") || ns.substring(with: range).contains("~~~") {
            range = NSRange(location: 0, length: ns.length)
        }
        styler.style(textStorage, range: range, settings: settings)
    }

    // MARK: Focus

    /// The range that stays fully visible for the current focus mode, or nil when focus is off.
    private func focusRange() -> NSRange? {
        let ns = textView.string as NSString
        let mode = settings.focusMode
        guard mode != .off, ns.length > 0 else { return nil }
        let caret = min(textView.selectedRange().location, ns.length)
        let current = ns.paragraphRange(for: NSRange(location: caret, length: 0))

        if mode == .sentence {
            var found = NSRange(location: caret, length: 0)
            ns.enumerateSubstrings(in: current, options: [.bySentences, .substringNotRequired]) { _, sentence, enclosing, stop in
                if sentence.location <= caret {
                    found = sentence
                }
                if NSMaxRange(enclosing) > caret { stop.pointee = true }
            }
            return found
        }

        // Current paragraph plus the previous non-empty ones (the context you're writing from).
        var start = current.location
        var remaining = mode.paragraphCount - 1
        var cursor = current.location
        while remaining > 0 && cursor > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
            cursor = previous.location
            let content = ns.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                start = previous.location
                remaining -= 1
            }
        }
        return NSRange(location: start, length: NSMaxRange(current) - start)
    }

    private func updateFocus() {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let all = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        guard let focus = focusRange() else { return }

        let palette = settings.palette
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: settings.focusStyle == .hide ? palette.background : palette.dimmed,
            .backgroundColor: palette.background,
        ]
        let before = NSRange(location: 0, length: focus.location)
        let after = NSRange(location: NSMaxRange(focus), length: length - NSMaxRange(focus))
        if before.length > 0 { layoutManager.addTemporaryAttributes(attributes, forCharacterRange: before) }
        if after.length > 0 { layoutManager.addTemporaryAttributes(attributes, forCharacterRange: after) }
    }

    // MARK: Typewriter scrolling

    private func centerCaret() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let caret = textView.selectedRange()
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: caret.location, length: 0),
                                              actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        if layoutManager.extraLineFragmentTextContainer != nil && caret.location == (textView.string as NSString).length {
            rect = layoutManager.extraLineFragmentRect
        }
        let y = rect.midY + textView.textContainerOrigin.y - scrollView.contentSize.height / 2
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        updateFocus()
        onCaretMove?(caretLocation)
        if settings.typewriter {
            // Run after NSTextView's own scroll-to-caret so ours wins.
            DispatchQueue.main.async { [weak self] in self?.centerCaret() }
        }
    }

    func textDidChange(_ notification: Notification) {
        updateFocus()
        onTextChange?()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateWordCount), object: nil)
        perform(#selector(updateWordCount), with: nil, afterDelay: 0.4)
    }

    // MARK: Status line

    @objc private func updateWordCount() {
        let ns = textView.string as NSString
        var count = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        wordCount = count
        updateStatus()
    }

    private func updateStatus() {
        let palette = settings.palette
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: palette.muted,
        ]
        let line = NSMutableAttributedString()
        if settings.grammarColors {
            let legend: [(String, NSColor)] = [("Subject", palette.subject), ("Predicate", palette.predicate),
                                               ("Object", palette.object), ("Modifier", palette.modifier)]
            for (name, color) in legend {
                line.append(NSAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color]))
                line.append(NSAttributedString(string: name + "   ", attributes: attributes))
            }
        }
        let focus = settings.focusMode == .off ? "" : "Focus: \(settings.focusMode.title)   "
        line.append(NSAttributedString(string: "\(focus)\(wordCount) words", attributes: attributes))
        statusLabel.attributedStringValue = line
    }
}
