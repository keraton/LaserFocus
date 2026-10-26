import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let settings = Settings.shared
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 10.14, *) {
            // Follow the OS light/dark switch when the theme is "System".
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                guard self?.settings.theme == .system else { return }
                NotificationCenter.default.post(name: .settingsChanged, object: nil)
            }
        }
    }

    // MARK: Actions

    @objc func setTheme(_ sender: NSMenuItem) {
        settings.theme = [ThemeChoice.light, .dark, .system][sender.tag]
    }

    @objc func toggleTheme(_ sender: Any?) {
        settings.theme = settings.isDark ? .light : .dark
    }

    @objc func setFocusMode(_ sender: NSMenuItem) {
        settings.focusMode = FocusMode(rawValue: sender.tag) ?? .off
    }

    @objc func toggleFocusStyle(_ sender: Any?) {
        settings.focusStyle = settings.focusStyle == .dim ? .hide : .dim
    }

    @objc func toggleGrammarColors(_ sender: Any?) {
        settings.grammarColors.toggle()
    }

    @objc func toggleAutocomplete(_ sender: Any?) {
        settings.autocomplete.toggle()
    }

    @objc func toggleOutline(_ sender: Any?) { toggleSidebar(.outline) }
    @objc func toggleNotes(_ sender: Any?) { toggleSidebar(.notes) }

    /// Shows the sidebar on `tab`, or hides it if it is already showing that tab.
    private func toggleSidebar(_ tab: SidebarTab) {
        if settings.showSidebar && settings.sidebarTab == tab {
            settings.showSidebar = false
        } else {
            settings.sidebarTab = tab
            settings.showSidebar = true
        }
    }

    @objc func toggleCoachNudges(_ sender: Any?) { settings.coachNudges.toggle() }
    @objc func toggleCoachSharesText(_ sender: Any?) { settings.coachSharesText.toggle() }

    @objc func setAPIKey(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = "The writing coach is powered by Claude. Paste an API key from console.anthropic.com. It is stored in your Mac's Keychain and only sent to Anthropic."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = Keychain.hasAPIKey ? "A key is saved — paste a new one to replace it" : "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if Keychain.hasAPIKey { alert.addButton(withTitle: "Remove Key") }
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn where !field.stringValue.isEmpty:
            Keychain.setAPIKey(field.stringValue)
        case .alertThirdButtonReturn:
            Keychain.setAPIKey(nil)
        default:
            return
        }
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    @objc func toggleTypewriter(_ sender: Any?) {
        settings.typewriter.toggle()
    }

    @objc func setFontStyle(_ sender: NSMenuItem) {
        settings.fontStyle = [FontStyle.serif, .sans, .mono][sender.tag]
    }

    @objc func biggerText(_ sender: Any?) { settings.fontSize += 1 }
    @objc func smallerText(_ sender: Any?) { settings.fontSize -= 1 }
    @objc func defaultTextSize(_ sender: Any?) { settings.fontSize = 18 }

    @objc func showMarkdownHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "LaserFocus Quick Reference"
        alert.informativeText = """
        Markdown: # Heading, **bold**, *italic*, `code`, ~~strike~~, > quote, - list, [link](url), ``` code block

        Focus: ⌘0 off, ⌘1 sentence, ⌘2 / ⌘3 / ⌘4 one, two or three paragraphs. ⇧⌘D switches between dimming and hiding the rest.

        Autocomplete: suggestions appear faintly after the caret. Press Tab to accept, Esc to dismiss, ⌥Esc for the full list. The language follows what you write; manage dictionaries in Edit ▸ Spelling and Grammar.

        Outline (⌃⌘S): shows the heading hierarchy in a sidebar. Click a heading to jump to it.

        Annotations: select text and press ⌥⌘A (or right-click ▸ Add Annotation) to attach a note without changing your text. ⌃⌘A shows all notes. Notes are saved invisibly at the end of the .md file.

        Coach (⌃⌘K): a Claude-powered coach on the right. Click "Plan my writing" to get a schedule you approve or change; it then reminds you every time you open the document and nudges you when you pause mid-sentence, keep rewriting, or go idle. Needs an Anthropic API key (Coach menu).

        Grammar colors (⌥⌘G) estimate subject, predicate, object and modifiers using macOS's language tagger.
        """
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setTheme(_:)):
            item.state = [ThemeChoice.light, .dark, .system][item.tag] == settings.theme ? .on : .off
        case #selector(setFocusMode(_:)):
            item.state = item.tag == settings.focusMode.rawValue ? .on : .off
        case #selector(toggleFocusStyle(_:)):
            item.state = settings.focusStyle == .hide ? .on : .off
        case #selector(toggleGrammarColors(_:)):
            item.state = settings.grammarColors ? .on : .off
        case #selector(toggleAutocomplete(_:)):
            item.state = settings.autocomplete ? .on : .off
        case #selector(toggleOutline(_:)):
            item.state = settings.showSidebar && settings.sidebarTab == .outline ? .on : .off
        case #selector(toggleNotes(_:)):
            item.state = settings.showSidebar && settings.sidebarTab == .notes ? .on : .off
        case #selector(toggleCoachNudges(_:)):
            item.state = settings.coachNudges ? .on : .off
        case #selector(toggleCoachSharesText(_:)):
            item.state = settings.coachSharesText ? .on : .off
        case #selector(toggleTypewriter(_:)):
            item.state = settings.typewriter ? .on : .off
        case #selector(setFontStyle(_:)):
            item.state = [FontStyle.serif, .sans, .mono][item.tag] == settings.fontStyle ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: Menu construction

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(coachMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("LaserFocus Quick Reference", #selector(showMarkdownHelp(_:)), "?"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services, title: "Services"))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        // NSDocumentController fills any submenu containing clearRecentDocuments:.
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), ""))
        menu.addItem(submenu(recent, title: "Open Recent"))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save…", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item("Rename…", #selector(NSDocument.rename(_:)), ""))
        menu.addItem(item("Move To…", #selector(NSDocument.move(_:)), ""))
        let saveAs = item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option])
        saveAs.isAlternate = true
        menu.addItem(saveAs)
        menu.addItem(item("Revert To…", #selector(NSDocument.revertToSaved(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        menu.addItem(item("Print…", #selector(NSView.printView(_:)), "p"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        let findAction = #selector(NSTextView.performTextFinderAction(_:))
        find.addItem(item("Find…", findAction, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        find.addItem(item("Find and Replace…", findAction, "f", [.command, .option],
                          tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        find.addItem(item("Find Next", findAction, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        find.addItem(item("Find Previous", findAction, "g", [.command, .shift],
                          tag: NSTextFinder.Action.previousMatch.rawValue))
        find.addItem(item("Use Selection for Find", findAction, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        find.addItem(item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"))
        menu.addItem(submenu(find, title: "Find"))

        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""))
        spelling.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)), ""))
        spelling.addItem(item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), ""))
        menu.addItem(submenu(spelling, title: "Spelling and Grammar"))

        let substitutions = NSMenu(title: "Substitutions")
        substitutions.addItem(item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), ""))
        substitutions.addItem(.separator())
        substitutions.addItem(item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:)), ""))
        substitutions.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), ""))
        substitutions.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), ""))
        substitutions.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)), ""))
        menu.addItem(submenu(substitutions, title: "Substitutions"))

        menu.addItem(.separator())
        menu.addItem(item("Add Annotation", #selector(DocumentViewController.addAnnotation(_:)), "a", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Autocomplete While Typing", #selector(toggleAutocomplete(_:)), ""))
        menu.addItem(item("Show Completions", #selector(NSTextView.complete(_:)), "\u{1b}", [.option]))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")

        menu.addItem(item("Show Outline", #selector(toggleOutline(_:)), "s", [.command, .control]))
        menu.addItem(item("Show Annotations", #selector(toggleNotes(_:)), "a", [.command, .control]))
        menu.addItem(.separator())

        let theme = NSMenu(title: "Theme")
        theme.addItem(item("Light", #selector(setTheme(_:)), "", tag: 0))
        theme.addItem(item("Dark", #selector(setTheme(_:)), "", tag: 1))
        theme.addItem(item("Match System", #selector(setTheme(_:)), "", tag: 2))
        theme.addItem(.separator())
        theme.addItem(item("Toggle Light/Dark", #selector(toggleTheme(_:)), "l", [.command, .shift]))
        menu.addItem(submenu(theme, title: "Theme"))
        menu.addItem(.separator())

        for mode in [FocusMode.off, .sentence, .oneParagraph, .twoParagraphs, .threeParagraphs] {
            menu.addItem(item("Focus: \(mode.title)", #selector(setFocusMode(_:)), "\(mode.rawValue)", tag: mode.rawValue))
        }
        menu.addItem(item("Hide Unfocused Text", #selector(toggleFocusStyle(_:)), "d", [.command, .shift]))
        menu.addItem(item("Typewriter Scrolling", #selector(toggleTypewriter(_:)), "t", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Grammar Colors", #selector(toggleGrammarColors(_:)), "g", [.command, .option]))
        menu.addItem(.separator())

        let font = NSMenu(title: "Font")
        font.addItem(item("Serif", #selector(setFontStyle(_:)), "", tag: 0))
        font.addItem(item("Sans Serif", #selector(setFontStyle(_:)), "", tag: 1))
        font.addItem(item("Monospaced", #selector(setFontStyle(_:)), "", tag: 2))
        font.addItem(.separator())
        font.addItem(item("Bigger", #selector(biggerText(_:)), "="))
        font.addItem(item("Smaller", #selector(smallerText(_:)), "-"))
        font.addItem(item("Default Size", #selector(defaultTextSize(_:)), ""))
        menu.addItem(submenu(font, title: "Font"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private func coachMenu() -> NSMenu {
        let menu = NSMenu(title: "Coach")
        menu.addItem(item("Show Coach", #selector(DocumentViewController.toggleCoach(_:)), "k", [.command, .control]))
        menu.addItem(item("Plan My Writing…", #selector(DocumentViewController.planWriting(_:)), "p", [.command, .control]))
        menu.addItem(item("Message Coach", #selector(DocumentViewController.messageCoach(_:)), "m", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Nudge Me When I'm Stuck", #selector(toggleCoachNudges(_:)), ""))
        menu.addItem(item("Share Current Paragraph With Coach", #selector(toggleCoachSharesText(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Anthropic API Key…", #selector(setAPIKey(_:)), ""))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private func submenu(_ menu: NSMenu, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
