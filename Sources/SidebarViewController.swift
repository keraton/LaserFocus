import AppKit

/// Left sidebar with two tabs: the heading outline and the annotation notes.
final class SidebarViewController: NSViewController {
    let outline = OutlineViewController()
    let notes: AnnotationsViewController

    private let settings = Settings.shared
    private let tabs = NSSegmentedControl(labels: ["Outline", "Notes"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let container = NSView()

    init(store: AnnotationStore) {
        notes = AnnotationsViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        root.wantsLayer = true

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.controlSize = .small
        tabs.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            // Leave room for the transparent title bar.
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        for child in [outline, notes] as [NSViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: container.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        NotificationCenter.default.addObserver(self, selector: #selector(applySettings),
                                               name: .settingsChanged, object: nil)
        applySettings()
    }

    @objc private func tabChanged() {
        settings.sidebarTab = tabs.selectedSegment == 1 ? .notes : .outline
    }

    @objc private func applySettings() {
        view.layer?.backgroundColor = settings.palette.sidebar.cgColor
        let tab = settings.sidebarTab
        tabs.selectedSegment = tab == .notes ? 1 : 0
        outline.view.isHidden = tab != .outline
        notes.view.isHidden = tab != .notes
    }
}
