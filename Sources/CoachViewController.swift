import AppKit

/// Right-hand panel: plan progress at the top, the conversation with the coach below,
/// and a message field at the bottom.
final class CoachViewController: NSViewController, NSTextFieldDelegate {
    private let coach: WritingCoach
    private let settings = Settings.shared

    private let titleLabel = NSTextField(labelWithString: "Coach")
    private let summaryBox = NSStackView()
    private let scrollView = NSScrollView()
    private let transcript = NSStackView()
    private let thinkingLabel = NSTextField(labelWithString: "Coach is thinking…")
    private let errorLabel = WrappingTextField()
    private let input = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    /// Identifies what the transcript currently shows, so progress updates don't rebuild it.
    private var renderedTranscript = ""

    init(coach: WritingCoach) {
        self.coach = coach
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        root.wantsLayer = true

        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)

        summaryBox.orientation = .vertical
        summaryBox.alignment = .leading
        summaryBox.spacing = 6
        summaryBox.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        summaryBox.wantsLayer = true
        summaryBox.layer?.cornerRadius = 8

        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 8
        transcript.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
        transcript.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedContainer()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(transcript)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        thinkingLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.isEditable = false
        errorLabel.isBordered = false
        errorLabel.drawsBackground = false
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = NSColor.systemRed

        input.placeholderString = "Message your coach…"
        input.delegate = self
        input.target = self
        input.action = #selector(sendMessage)
        input.focusRingType = .none
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small

        for view in [titleLabel, summaryBox, scrollView, thinkingLabel, errorLabel, input, sendButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            summaryBox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            summaryBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            summaryBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: summaryBox.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            transcript.topAnchor.constraint(equalTo: document.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            thinkingLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            thinkingLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            errorLabel.topAnchor.constraint(equalTo: thinkingLabel.bottomAnchor, constant: 2),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            input.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 6),
            input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            input.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
        ])
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .coachChanged, object: coach.store)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .settingsChanged, object: nil)
        refresh()
    }

    // MARK: Actions

    @objc private func sendMessage() {
        let text = input.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !coach.isThinking else { return }
        input.stringValue = ""
        coach.send(text)
    }

    @objc func planWriting() {
        guard !coach.isThinking else { return }
        coach.startPlanning()
    }

    @objc private func approvePlan() {
        coach.approvePendingPlan()
    }

    @objc private func requestChanges() {
        input.placeholderString = "What should change in the plan?"
        view.window?.makeFirstResponder(input)
    }

    @objc private func addAPIKey() {
        NSApp.sendAction(#selector(AppDelegate.setAPIKey(_:)), to: nil, from: self)
    }

    func focusInput() {
        view.window?.makeFirstResponder(input)
    }

    // MARK: Rendering

    @objc private func refresh() {
        let palette = settings.palette
        view.layer?.backgroundColor = palette.sidebar.cgColor
        titleLabel.textColor = palette.text
        thinkingLabel.textColor = palette.muted
        thinkingLabel.isHidden = !coach.isThinking
        errorLabel.stringValue = coach.lastError ?? ""
        errorLabel.isHidden = coach.lastError == nil
        sendButton.isEnabled = !coach.isThinking
        if coach.store.data.pendingPlan == nil { input.placeholderString = "Message your coach…" }

        renderSummary(palette)
        renderTranscript(palette)
    }

    private func renderSummary(_ palette: Palette) {
        summaryBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        summaryBox.layer?.backgroundColor = palette.background.cgColor

        if !Keychain.hasAPIKey {
            summaryBox.addArrangedSubview(label("The coach uses Claude. Add your Anthropic API key to plan and chat.", size: 12, color: palette.muted))
            summaryBox.addArrangedSubview(button("Add API Key…", #selector(addAPIKey)))
        }

        guard let plan = coach.store.data.plan, let status = coach.status() else {
            summaryBox.addArrangedSubview(label("No writing plan yet", size: 12, color: palette.text, bold: true))
            summaryBox.addArrangedSubview(label("Tell the coach what you're writing and get a schedule you can stick to.", size: 11, color: palette.muted))
            summaryBox.addArrangedSubview(button("Plan my writing", #selector(planWriting)))
            return
        }

        summaryBox.addArrangedSubview(label(plan.title, size: 12, color: palette.text, bold: true))
        summaryBox.addArrangedSubview(label(plan.cadence, size: 11, color: palette.muted))
        if status.todayGoal > 0 {
            summaryBox.addArrangedSubview(label("Today: \(status.doneToday) / \(status.todayGoal) \(status.unit)", size: 11, color: palette.text))
            summaryBox.addArrangedSubview(ProgressBar(fraction: Double(status.doneToday) / Double(max(1, status.todayGoal)),
                                                      color: palette.accent, track: palette.codeBackground))
        } else {
            summaryBox.addArrangedSubview(label("Rest day — \(status.doneToday) \(status.unit) written today", size: 11, color: palette.text))
        }
        summaryBox.addArrangedSubview(label("Overall: \(status.current) / \(status.totalTarget) \(status.unit) · \(status.daysLeft) days left", size: 11, color: palette.text))
        summaryBox.addArrangedSubview(ProgressBar(fraction: Double(status.current) / Double(max(1, status.totalTarget)),
                                                  color: palette.object, track: palette.codeBackground))
        let standing = status.behind > 0 ? "Behind by \(status.behind) \(status.unit)" : "On track"
        summaryBox.addArrangedSubview(label(standing, size: 11, color: status.behind > 0 ? palette.predicate : palette.object, bold: true))
        summaryBox.addArrangedSubview(button("Revise plan", #selector(planWriting)))

        for view in summaryBox.arrangedSubviews where view is ProgressBar {
            view.widthAnchor.constraint(equalTo: summaryBox.widthAnchor, constant: -24).isActive = true
        }
    }

    private func renderTranscript(_ palette: Palette) {
        let data = coach.store.data
        let signature = [data.chat.last?.id ?? "", "\(data.chat.count)", data.plan?.id ?? "", data.pendingPlan?.id ?? "",
                         settings.isDark ? "dark" : "light"].joined(separator: "|")
        guard signature != renderedTranscript else { return }
        renderedTranscript = signature
        transcript.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in data.chat where !entry.hidden {
            let bubble: NSView
            if let plan = entry.plan {
                let state: PlanCard.State = plan.id == data.plan?.id ? .approved
                    : plan.id == data.pendingPlan?.id ? .pending : .superseded
                bubble = PlanCard(plan: plan, state: state, palette: palette, target: self,
                                  approve: #selector(approvePlan), change: #selector(requestChanges))
            } else {
                bubble = Bubble(text: entry.text, fromWriter: entry.role == .user, palette: palette)
            }
            transcript.addArrangedSubview(bubble)
            bubble.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -24).isActive = true
        }
        view.layoutSubtreeIfNeeded()
        if let document = scrollView.documentView {
            let bottom = max(0, document.frame.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func label(_ text: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSTextField {
        let field = WrappingTextField()
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.stringValue = text
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }
}

private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

private final class ProgressBar: NSView {
    init(fraction: Double, color: NSColor, track: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = track.cgColor
        layer?.cornerRadius = 3
        heightAnchor.constraint(equalToConstant: 6).isActive = true

        let fill = NSView()
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.backgroundColor = color.cgColor
        fill.layer?.cornerRadius = 3
        addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.widthAnchor.constraint(equalTo: widthAnchor, multiplier: CGFloat(min(1, max(0.02, fraction)))),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One chat message. The writer's messages are tinted and indented from the left.
private final class Bubble: NSView {
    init(text: String, fromWriter: Bool, palette: Palette) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let background = NSView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.backgroundColor = (fromWriter ? palette.accent.withAlphaComponent(0.18) : palette.background).cgColor

        let label = WrappingTextField()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = true
        label.isBordered = false
        label.drawsBackground = false
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = palette.text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(background)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: fromWriter ? 36 : 0),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: fromWriter ? 0 : -24),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A proposed plan with Approve / Request changes buttons while it is pending.
private final class PlanCard: NSView {
    enum State { case pending, approved, superseded }

    init(plan: WritingPlan, state: State, palette: Palette, target: AnyObject, approve: Selector, change: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = palette.background.cgColor
        layer?.borderWidth = state == .pending ? 2 : 1
        layer?.borderColor = (state == .pending ? palette.accent : palette.muted.withAlphaComponent(0.25)).cgColor
        alphaValue = state == .superseded ? 0.55 : 1

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        func add(_ text: String, size: CGFloat = 12, bold: Bool = false, color: NSColor = palette.text) {
            let field = WrappingTextField()
            field.isEditable = false
            field.isSelectable = true
            field.isBordered = false
            field.drawsBackground = false
            field.stringValue = text
            field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            field.textColor = color
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }

        add("PROPOSED PLAN", size: 10, bold: true, color: palette.accent)
        add(plan.title, size: 13, bold: true)
        add(plan.summary, color: palette.muted)
        add("Rhythm: \(plan.cadence)")
        let days = plan.writingDays.isEmpty ? "every day" : plan.writingDays.map { $0.capitalized }.joined(separator: ", ")
        add("\(plan.dailyTarget) \(plan.unit) per writing day (\(days))")
        add("Goal: \(plan.totalTarget) \(plan.unit), \(plan.startDate) → \(plan.deadline)")
        for milestone in plan.milestones {
            add("• \(milestone.title): \(milestone.target) \(plan.unit) by \(milestone.due)", size: 11, color: palette.muted)
        }

        switch state {
        case .pending:
            let approveButton = NSButton(title: "Approve", target: target, action: approve)
            approveButton.bezelStyle = .rounded
            let changeButton = NSButton(title: "Request changes", target: target, action: change)
            changeButton.bezelStyle = .rounded
            let row = NSStackView(views: [approveButton, changeButton])
            row.spacing = 6
            stack.addArrangedSubview(row)
        case .approved:
            add("✓ Approved", size: 11, bold: true, color: palette.object)
        case .superseded:
            add("Replaced by a newer proposal", size: 11, color: palette.muted)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
