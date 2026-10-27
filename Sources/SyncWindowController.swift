import AppKit

/// File ▸ Writing Library ▸ Sync Settings…: connect a GitHub account, then create a new
/// library or connect this Mac to an existing one. Once set up, shows the sync status.
final class SyncWindowController: NSWindowController {
    static let shared = SyncWindowController()

    private let library = SyncLibrary.shared
    private let content = NSStackView()
    private var account: GitHub.Account?
    private var tokenSource: String?
    private var accountError: String?
    private var gitReady: Bool?
    private var repositories: [String] = []
    private var busy = false
    private var message: (text: String, isError: Bool)?

    // Setup form state, kept across rebuilds.
    private var connecting = false
    private var repositoryName = "writing"
    private var chosenFolder: URL?
    private let nameField = NSTextField()
    private let repositoryBox = NSComboBox()

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
                            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Writing Library Sync"
        panel.hidesOnDeactivate = false
        super.init(window: panel)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 500),
        ])
        panel.contentView = root

        nameField.stringValue = repositoryName
        nameField.target = self
        nameField.action = #selector(nameChanged)
        repositoryBox.completes = true
        repositoryBox.numberOfVisibleItems = 12
        repositoryBox.placeholderString = "owner/repository"

        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .syncStateChanged, object: nil)
        NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: nameField,
                                               queue: .main) { [weak self] _ in self?.nameChanged() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        rebuild()
        window?.center()
        super.showWindow(sender)
        refreshAccount()
    }

    // MARK: Loading

    private func refreshAccount() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ready = Git.isAvailable
            var account: GitHub.Account?
            var source: String?
            var failure: String?
            var repositories: [String] = []
            if let token = GitHub.token() {
                source = token.source
                do {
                    account = try GitHub.account(token: token.value)
                    repositories = (try? GitHub.repositories(token: token.value)) ?? []
                } catch {
                    failure = error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                self.gitReady = ready
                self.account = account
                self.tokenSource = source
                self.accountError = failure
                self.repositories = repositories
                self.rebuild()
            }
        }
    }

    // MARK: Layout

    @objc private func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }

        add(heading("Sync your writing between Macs"))
        add(note("Documents in your writing library sync through a private GitHub repository, with their notes, writing outline and coach chat. Your custom dictionary syncs too."))

        add(section("GitHub account"))
        if let account = account {
            add(row([label("✓ Connected as \(account.login)" + (tokenSource == "GitHub CLI" ? " (using the GitHub CLI login)" : "")),
                     tokenSource == "token" ? button("Remove Token", #selector(removeToken)) : nil]))
        } else if let error = accountError {
            add(errorLabel(error))
            add(row([button("Use a Token…", #selector(enterToken))]))
        } else if gitReady == nil {
            add(note("Checking…"))
        } else {
            add(note("Not connected. Paste a GitHub token, or install the GitHub CLI and run “gh auth login” in Terminal."))
            add(row([button("Use a Token…", #selector(enterToken)), button("Create a Token on GitHub", #selector(openTokenPage))]))
        }
        if gitReady == false {
            add(errorLabel(SyncLibrary.SetupError.gitMissing.localizedDescription))
        }

        if library.isConfigured {
            buildStatus()
        } else {
            buildSetup()
        }

        if busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            add(row([spinner, label(message?.text ?? "Working…")]))
        } else if let message = message {
            add(message.isError ? errorLabel(message.text) : note(message.text))
        }
        window?.setContentSize(content.fittingSize)
    }

    private func buildStatus() {
        add(section("Library"))
        if let folder = library.folder {
            add(row([label("Folder: " + (folder.path as NSString).abbreviatingWithTildeInPath),
                     button("Show in Finder", #selector(showFolder))]))
        }
        if let repository = library.repository {
            add(row([label("GitHub: \(repository) (private)"), button("Open on GitHub", #selector(openRepository))]))
        }
        if let error = library.lastError {
            add(errorLabel("Last sync failed: \(error)"))
        } else {
            add(label("Status: " + (library.statusText ?? "")))
        }
        add(note("LaserFocus syncs when you open a document, about a minute after you stop typing, when you close a document and when you quit. Save documents in the library folder, or use File ▸ Writing Library ▸ Move Document to Library."))
        add(row([button("Sync Now", #selector(syncNow), primary: true), button("Stop Syncing…", #selector(stopSyncing))]))
    }

    private func buildSetup() {
        let modes = NSSegmentedControl(labels: ["Create a New Library", "Use an Existing Library"],
                                       trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modes.selectedSegment = connecting ? 1 : 0
        add(section("Library"))
        add(modes)

        if connecting {
            add(note("Choose the library you created on your other Mac. It is downloaded into a new folder here."))
            repositoryBox.removeAllItems()
            repositoryBox.addItems(withObjectValues: repositories)
            if repositoryBox.stringValue.isEmpty, let guess = repositories.first(where: { $0.hasSuffix("/writing") }) {
                repositoryBox.stringValue = guess
            }
            repositoryBox.widthAnchor.constraint(equalToConstant: 300).isActive = true
            add(row([label("Repository:"), repositoryBox]))
        } else {
            add(note("A new private repository is created on GitHub, and a folder for your documents on this Mac."))
            nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
            add(row([label("Repository name:"), nameField]))
        }
        add(row([label("Folder: " + (folder().path as NSString).abbreviatingWithTildeInPath), button("Choose…", #selector(chooseFolder))]))
        let go = button(connecting ? "Download Library" : "Create Library", #selector(setUp), primary: true)
        go.isEnabled = account != nil && gitReady == true && !busy
        add(row([go]))
    }

    private func folder() -> URL {
        if let chosen = chosenFolder { return chosen }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = connecting
            ? (repositoryBox.stringValue.split(separator: "/").last.map(String.init) ?? "Writing")
            : repositoryName
        let folderName = name.isEmpty ? "Writing" : name.prefix(1).uppercased() + name.dropFirst()
        return documents.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        connecting = sender.selectedSegment == 1
        message = nil
        rebuild()
    }

    @objc private func nameChanged() {
        repositoryName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = connecting ? "Choose an empty folder for the library." : "Choose a folder for the library."
        panel.directoryURL = folder().deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenFolder = url
        rebuild()
    }

    @objc private func setUp() {
        window?.makeFirstResponder(nil)
        let target = folder()
        busy = true
        message = (connecting ? "Downloading your library…" : "Creating the private repository…", false)
        rebuild()
        let done: (Error?) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.busy = false
            self.message = error.map { ($0.localizedDescription, true) }
                ?? ("Your library is ready. Save documents in it to sync them.", false)
            self.rebuild()
        }
        if connecting {
            let repository = repositoryBox.stringValue.trimmingCharacters(in: .whitespaces)
            guard repository.contains("/") else {
                done(SyncLibrary.SetupError.failed("Enter the repository as owner/name, for example \(account?.login ?? "you")/writing."))
                return
            }
            library.connect(repository: repository, folder: target, completion: done)
        } else {
            let name = repositoryName.replacingOccurrences(of: " ", with: "-")
            guard !name.isEmpty else {
                done(SyncLibrary.SetupError.failed("Enter a name for the repository."))
                return
            }
            library.create(repositoryName: name, folder: target, completion: done)
        }
    }

    @objc private func enterToken() {
        let alert = NSAlert()
        alert.messageText = "Connect GitHub with a token"
        alert.informativeText = "Create a token on GitHub with the “repo” scope (Settings ▸ Developer settings ▸ Personal access tokens), then paste it here. It is stored in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "ghp_… or github_pat_…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let failure = Keychain.set(field.stringValue, for: Keychain.gitHubTokenAccount) {
            message = ("Couldn't save the token: \(failure)", true)
        } else {
            message = nil
        }
        account = nil
        accountError = nil
        rebuild()
        refreshAccount()
    }

    @objc private func removeToken() {
        Keychain.set(nil, for: Keychain.gitHubTokenAccount)
        account = nil
        rebuild()
        refreshAccount()
    }

    @objc private func openTokenPage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=LaserFocus")!)
    }

    @objc private func showFolder() {
        if let folder = library.folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    @objc private func openRepository() {
        if let repository = library.repository, let url = URL(string: "https://github.com/\(repository)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func syncNow() {
        library.syncNow()
    }

    @objc private func stopSyncing() {
        let alert = NSAlert()
        alert.messageText = "Stop syncing this Mac?"
        alert.informativeText = "Your documents stay in the folder and on GitHub; they just stop syncing on this Mac. You can connect again later."
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.disconnect()
        message = nil
        rebuild()
    }

    // MARK: Building blocks

    private func add(_ view: NSView) {
        content.addArrangedSubview(view)
        if view is NSTextField { view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true }
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        return field
    }

    private func section(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text.uppercased())
        field.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func errorLabel(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = .systemRed
        field.isSelectable = true
        return field
    }

    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if primary { button.keyEquivalent = "\r" }
        return button
    }

    private func row(_ views: [NSView?]) -> NSStackView {
        let stack = NSStackView(views: views.compactMap { $0 })
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }
}
