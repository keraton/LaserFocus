import AppKit

/// Sidebar list of annotation cards, in document order. Each card quotes the annotated
/// text and holds an editable note. Clicking a card selects its text in the editor.
final class AnnotationsViewController: NSViewController, NSTextFieldDelegate {
    var onReveal: ((Annotation) -> Void)?

    private let store: AnnotationStore
    private let settings = Settings.shared
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No annotations yet.\nSelect some text and press ⌥⌘A\nto add a note to it.")
    private var cards: [AnnotationCard] = []
    private var activeID: String?

    init(store: AnnotationStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 16, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = document

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0

        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
        ])
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .annotationsChanged, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .settingsChanged, object: nil)
        reload()
    }

    // MARK: Cards

    @objc func reload() {
        let palette = settings.palette
        emptyLabel.textColor = palette.muted
        emptyLabel.isHidden = !store.items.isEmpty

        cards.forEach { $0.removeFromSuperview() }
        cards = store.items.map { annotation in
            let card = AnnotationCard(annotation: annotation, palette: palette)
            card.noteField.delegate = self
            card.onClick = { [weak self] in self?.onReveal?(annotation) }
            card.onDelete = { [weak self] in self?.store.remove(annotation) }
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            return card
        }
        highlight(id: activeID)
    }

    /// Marks the card for the annotation under the caret.
    func highlight(_ annotation: Annotation?) {
        highlight(id: annotation?.id)
    }

    private func highlight(id: String?) {
        activeID = id
        for card in cards {
            card.isActive = card.annotation.id == id
            if card.isActive { card.scrollToVisible(card.bounds) }
        }
    }

    /// Puts the caret in a card's note field, e.g. right after the annotation is created.
    func beginEditing(_ annotation: Annotation) {
        guard let card = cards.first(where: { $0.annotation === annotation }) else { return }
        highlight(id: annotation.id)
        card.scrollToVisible(card.bounds)
        view.window?.makeFirstResponder(card.noteField)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let card = cards.first(where: { $0.noteField === field }) else { return }
        store.updateNote(card.annotation, to: field.stringValue)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class AnnotationCard: NSView {
    let annotation: Annotation
    let noteField = WrappingTextField()
    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?
    private let palette: Palette

    var isActive = false {
        didSet {
            layer?.borderColor = (isActive ? palette.annotation : palette.muted.withAlphaComponent(0.2)).cgColor
            layer?.borderWidth = isActive ? 2 : 1
        }
    }

    init(annotation: Annotation, palette: Palette) {
        self.annotation = annotation
        self.palette = palette
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = palette.background.cgColor

        let marker = NSView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.wantsLayer = true
        marker.layer?.backgroundColor = palette.annotation.cgColor
        marker.layer?.cornerRadius = 1.5

        let quote = NSTextField(labelWithString: annotation.length > 0 ? annotation.anchor : "(annotated text was deleted)")
        quote.translatesAutoresizingMaskIntoConstraints = false
        quote.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
        quote.textColor = palette.muted
        quote.lineBreakMode = .byTruncatingTail
        quote.maximumNumberOfLines = 2
        quote.cell?.wraps = true
        quote.cell?.truncatesLastVisibleLine = true
        quote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let delete = NSButton(title: "✕", target: nil, action: #selector(deleteClicked))
        delete.target = self
        delete.translatesAutoresizingMaskIntoConstraints = false
        delete.isBordered = false
        delete.font = NSFont.systemFont(ofSize: 10)
        delete.contentTintColorIfAvailable(palette.muted)
        delete.toolTip = "Delete annotation"

        noteField.translatesAutoresizingMaskIntoConstraints = false
        noteField.stringValue = annotation.note
        noteField.placeholderString = "Write a note…"
        noteField.font = NSFont.systemFont(ofSize: 13)
        noteField.textColor = palette.text
        noteField.isBordered = false
        noteField.drawsBackground = false
        noteField.focusRingType = .none
        noteField.cell?.wraps = true
        noteField.cell?.isScrollable = false
        noteField.usesSingleLineMode = false
        noteField.maximumNumberOfLines = 0
        noteField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [marker, quote, delete, noteField].forEach(addSubview)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            marker.topAnchor.constraint(equalTo: quote.topAnchor, constant: 1),
            marker.bottomAnchor.constraint(equalTo: quote.bottomAnchor, constant: -1),
            marker.widthAnchor.constraint(equalToConstant: 3),
            quote.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            quote.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 6),
            quote.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -4),
            delete.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            delete.widthAnchor.constraint(equalToConstant: 18),
            noteField.topAnchor.constraint(equalTo: quote.bottomAnchor, constant: 6),
            noteField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            noteField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            noteField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        isActive = false
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clicked() { onClick?() }
    @objc private func deleteClicked() { onDelete?() }
}

/// Multi-line text field whose height follows its wrapped text, including while typing.
final class WrappingTextField: NSTextField {
    private var lastWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        guard let cell = cell?.copy() as? NSCell else { return super.intrinsicContentSize }
        let text = currentEditor()?.string ?? stringValue
        cell.stringValue = text.isEmpty ? " " : text
        let width = frame.width > 0 ? frame.width : 200
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func layout() {
        super.layout()
        if frame.width != lastWidth {
            lastWidth = frame.width
            invalidateIntrinsicContentSize()
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }
}

private extension NSButton {
    func contentTintColorIfAvailable(_ color: NSColor) {
        if #available(macOS 10.14, *) { contentTintColor = color }
    }
}
