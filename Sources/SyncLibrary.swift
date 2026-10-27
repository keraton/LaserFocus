import AppKit

extension Notification.Name {
    /// Posted on the main queue whenever the sync status changes.
    static let syncStateChanged = Notification.Name("LaserFocusSyncStateChanged")
}

/// The writing library: a folder that is a git repository with a private GitHub repository
/// behind it. Documents saved in it, with their notes, outline and coach chat (all inside the
/// .md files) and the custom dictionary, sync between Macs:
///
/// - after a pause in saving, when a document closes, when the app quits, and every few minutes;
/// - by committing local changes, merging what other Macs pushed, and pushing the result;
/// - when both sides changed a file in ways git can't merge, the local version stays and the
///   other Mac's version is saved next to it as "name (from Other Mac).md". Nothing is lost.
final class SyncLibrary {
    static let shared = SyncLibrary()

    enum Phase: Equatable {
        case idle, syncing, offline, failed(String)
    }

    private(set) var phase: Phase = .idle { didSet { notify() } }
    private(set) var lastSync: Date? {
        get { defaults.object(forKey: Keys.lastSync) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastSync) }
    }

    var folder: URL? {
        defaults.string(forKey: Keys.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    /// "owner/name" of the GitHub repository.
    var repository: String? { defaults.string(forKey: Keys.repository) }
    var isConfigured: Bool { folder != nil && repository != nil }

    /// This Mac's name, written into commits so conflict copies can say where they came from.
    let macName: String = Host.current().localizedName ?? "another Mac"

    private enum Keys {
        static let folder = "syncLibraryPath"
        static let repository = "syncLibraryRepository"
        static let lastSync = "syncLibraryLastSync"
    }

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "LaserFocus.sync")
    private var debounce: Timer?
    private var periodic: Timer?
    private var running = false
    private var pendingCompletions: [() -> Void] = []
    private var runAgain = false
    private static let markerTrailer = "LaserFocus-Mac: "
    static let dictionaryPath = ".laserfocus/dictionary.txt"

    private func notify() {
        NotificationCenter.default.post(name: .syncStateChanged, object: self)
    }

    // MARK: Status

    /// One line for the status bar, or nil when the library isn't set up.
    var statusText: String? {
        guard isConfigured else { return nil }
        switch phase {
        case .syncing: return "Syncing…"
        case .offline: return "Offline · will sync later"
        case .failed: return "Sync problem · File ▸ Writing Library"
        case .idle:
            guard let date = lastSync else { return "Not synced yet" }
            let seconds = Date().timeIntervalSince(date)
            if seconds < 60 { return "Synced just now" }
            if seconds < 3600 { return "Synced \(Int(seconds / 60)) min ago" }
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
            formatter.timeStyle = .short
            return "Synced " + formatter.string(from: date)
        }
    }

    var lastError: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func contains(_ url: URL?) -> Bool {
        guard let url = url, let folder = folder else { return false }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: Scheduling

    func start() {
        guard periodic == nil else { return }
        periodic = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.notify()   // refreshes "Synced n min ago"
            if NSApp.isActive { self?.syncNow() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.syncIfStale() }
        syncNow()
    }

    /// Syncs unless that happened in the last minute, e.g. when a document is opened.
    func syncIfStale() {
        guard let last = lastSync else { return syncNow() }
        if Date().timeIntervalSince(last) > 60 { syncNow() }
    }

    /// Syncs after `delay` seconds without further calls: saving while typing keeps pushing it back.
    func scheduleSync(after delay: TimeInterval) {
        guard isConfigured else { return }
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.syncNow() }
    }

    func syncNow(completion: (() -> Void)? = nil) {
        guard isConfigured, let folder = folder, let repository = repository else {
            completion?()
            return
        }
        debounce?.invalidate()
        if let completion = completion { pendingCompletions.append(completion) }
        guard !running else {
            runAgain = true
            return
        }
        running = true
        phase = .syncing

        // Save open library documents first, so their latest text is committed.
        let group = DispatchGroup()
        for document in NSDocumentController.shared.documents where document.isDocumentEdited && contains(document.fileURL) {
            group.enter()
            document.autosave(withImplicitCancellability: false) { _ in group.leave() }
        }
        group.notify(queue: queue) {
            let token = GitHub.token()?.value
            let outcome = self.performSync(in: folder, repository: repository, token: token)
            DispatchQueue.main.async { self.finish(outcome, folder: folder) }
        }
    }

    private func finish(_ outcome: Outcome, folder: URL) {
        running = false
        switch outcome.result {
        case .synced:
            lastSync = Date()
            phase = .idle
        case .offline:
            phase = .offline
        case .failed(let message):
            phase = .failed(message)
            CoachLog.write("Sync failed: \(message)")
        case .busy:
            phase = .idle
            scheduleSync(after: 30)
        }
        reloadChangedDocuments(outcome.changedPaths, in: folder)
        if !outcome.conflictCopies.isEmpty { reportConflicts(outcome.conflictCopies) }

        if runAgain {
            runAgain = false
            syncNow()
        } else {
            let completions = pendingCompletions
            pendingCompletions = []
            completions.forEach { $0() }
        }
    }

    /// Open documents whose files changed in a merge show the merged text.
    private func reloadChangedDocuments(_ paths: [String], in folder: URL) {
        guard !paths.isEmpty else { return }
        let changed = Set(paths.map { folder.appendingPathComponent($0).standardizedFileURL.path })
        for document in NSDocumentController.shared.documents {
            guard let url = document.fileURL, changed.contains(url.standardizedFileURL.path),
                  !document.isDocumentEdited, let type = document.fileType else { continue }
            try? document.revert(toContentsOf: url, ofType: type)
        }
        if paths.contains(Self.dictionaryPath) { CustomDictionary.shared.reloadFromLibrary() }
    }

    private func reportConflicts(_ copies: [(original: String, copy: String)]) {
        let alert = NSAlert()
        alert.messageText = copies.count == 1 ? "A document was changed on two Macs" : "Some documents were changed on two Macs"
        alert.informativeText = copies.map {
            "“\($0.original)” keeps this Mac's version. The other version was saved as “\($0.copy)”."
        }.joined(separator: "\n\n") + "\n\nCompare them and keep what you need."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn, let folder = folder {
            NSWorkspace.shared.activateFileViewerSelecting(copies.map { folder.appendingPathComponent($0.copy) })
        }
    }

    // MARK: The sync itself (runs on `queue`)

    private struct Outcome {
        enum Result { case synced, offline, failed(String), busy }
        var result: Result = .synced
        var changedPaths: [String] = []
        var conflictCopies: [(original: String, copy: String)] = []
    }

    private func performSync(in folder: URL, repository: String, token: String?, attempt: Int = 1) -> Outcome {
        var outcome = Outcome()
        @discardableResult func git(_ arguments: String...) -> Git.Result { Git.run(arguments, in: folder, token: token) }

        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else {
            outcome.result = .failed("The library folder is missing or isn't a git repository: \(folder.path)")
            return outcome
        }

        // 1. Commit what changed here.
        git("add", "-A")
        let changes = git("status", "--porcelain", "-z").paths
        if !changes.isEmpty {
            let paths = changes.map { String($0.dropFirst(3)) }
            let names = paths.filter { !$0.hasPrefix(".") }.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            let subject = names.isEmpty ? (paths.contains(Self.dictionaryPath) ? "Update custom dictionary" : "Update library settings")
                : "Update " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
            let commit = git("commit", "-q", "-m", "\(subject) from \(macName)\n\n\(Self.markerTrailer)\(macName)")
            if !commit.ok {
                outcome.result = .failed(commit.message)
                return outcome
            }
        }

        // 2. Fetch what other Macs pushed.
        let fetch = git("fetch", "-q", "origin")
        if !fetch.ok {
            outcome.result = Self.looksOffline(fetch.error) ? .offline : .failed(fetch.message)
            return outcome
        }
        let current = git("symbolic-ref", "--short", "HEAD").text
        let branch = current.isEmpty ? "main" : current
        let remote = "origin/\(branch)"
        let remoteExists = git("rev-parse", "--verify", "-q", remote).ok

        // 3. Merge it in.
        if remoteExists && !git("merge-base", "--is-ancestor", remote, "HEAD").ok {
            // Don't merge into a file the writer is typing in right now; try again shortly.
            let incoming = git("diff", "--name-only", "-z", "HEAD...\(remote)").paths
            if isEditingAny(incoming, in: folder) {
                outcome.result = .busy
                return outcome
            }
            let before = git("rev-parse", "HEAD").text
            let otherMac = otherMacName(git("log", "-1", "--format=%B", remote).text)
            let merge = git("merge", "--no-edit", "-q", remote)
            if !merge.ok {
                let conflicted = git("diff", "--name-only", "--diff-filter=U", "-z").paths
                guard !conflicted.isEmpty else {
                    git("merge", "--abort")
                    // A document was saved after the commit above; the next round includes it.
                    outcome.result = merge.error.contains("would be overwritten") ? .busy : .failed(merge.message)
                    return outcome
                }
                for path in conflicted {
                    if let copy = resolveConflict(path, in: folder, otherMac: otherMac, git: git) {
                        outcome.conflictCopies.append((path, copy))
                    }
                }
                let commit = git("commit", "-q", "--no-edit", "-m", "Merge changes from \(otherMac)\n\n\(Self.markerTrailer)\(macName)")
                if !commit.ok {
                    outcome.result = .failed(commit.message)
                    return outcome
                }
            }
            // A clean text merge can still break the JSON in hidden blocks; keep both versions then.
            let merged = git("diff", "--name-only", "-z", before, "HEAD").paths
            var repaired = false
            for path in merged where path.hasSuffix(".md") && !outcome.conflictCopies.contains(where: { $0.original == path }) {
                let url = folder.appendingPathComponent(path)
                guard let text = try? String(contentsOf: url, encoding: .utf8), !Self.hiddenBlocksAreValid(text) else { continue }
                let theirs = git("show", "\(remote):\(path)").output
                let ours = git("show", "\(before):\(path)").output
                // Only when the merge broke it: both versions were fine on their own.
                guard Self.hiddenBlocksAreValid(String(data: ours, encoding: .utf8) ?? ""),
                      Self.hiddenBlocksAreValid(String(data: theirs, encoding: .utf8) ?? "") else { continue }
                let copy = Self.conflictCopyName(for: path, otherMac: otherMac, in: folder)
                try? theirs.write(to: folder.appendingPathComponent(copy))
                try? ours.write(to: url)
                outcome.conflictCopies.append((path, copy))
                repaired = true
            }
            if repaired {
                git("add", "-A")
                git("commit", "-q", "-m", "Keep both versions of documents changed on two Macs\n\n\(Self.markerTrailer)\(macName)")
            }
            outcome.changedPaths = git("diff", "--name-only", "-z", before, "HEAD").paths
        }

        // 4. Push.
        let ahead = !remoteExists || !git("merge-base", "--is-ancestor", "HEAD", remote).ok
        if ahead {
            let push = git("push", "-q", "-u", "origin", "HEAD:\(branch)")
            if !push.ok {
                if Self.looksOffline(push.error) {
                    outcome.result = .offline
                } else if attempt < 3 && (push.error.contains("rejected") || push.error.contains("fetch first")) {
                    // Another Mac pushed in the meantime: merge that too, then push again.
                    let retry = performSync(in: folder, repository: repository, token: token, attempt: attempt + 1)
                    return Outcome(result: retry.result, changedPaths: outcome.changedPaths + retry.changedPaths,
                                   conflictCopies: outcome.conflictCopies + retry.conflictCopies)
                } else {
                    outcome.result = .failed(push.message)
                }
            }
        }
        return outcome
    }

    /// Keeps this Mac's version of a conflicted file and saves the other one next to it.
    /// Returns the copy's path, if one was made.
    private func resolveConflict(_ path: String, in folder: URL, otherMac: String,
                                 git: (String...) -> Git.Result) -> String? {
        let ours = git("show", ":2:\(path)")
        let theirs = git("show", ":3:\(path)")
        if path == Self.dictionaryPath {
            // Word lists simply combine.
            let words = Set((String(data: ours.output, encoding: .utf8) ?? "").split(separator: "\n")
                + (String(data: theirs.output, encoding: .utf8) ?? "").split(separator: "\n"))
            let text = words.map(String.init).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .joined(separator: "\n") + "\n"
            try? text.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
            _ = git("add", "--", path)
            return nil
        }
        if !ours.ok {           // deleted here, changed there: keep theirs
            _ = git("checkout", "--theirs", "--", path)
            _ = git("add", "--", path)
            return nil
        }
        if !theirs.ok {         // changed here, deleted there: keep ours
            _ = git("checkout", "--ours", "--", path)
            _ = git("add", "--", path)
            return nil
        }
        let copy = Self.conflictCopyName(for: path, otherMac: otherMac, in: folder)
        try? theirs.output.write(to: folder.appendingPathComponent(copy))
        _ = git("checkout", "--ours", "--", path)
        _ = git("add", "--", path, copy)
        return copy
    }

    private func isEditingAny(_ paths: [String], in folder: URL) -> Bool {
        guard !paths.isEmpty else { return false }
        let targets = Set(paths.map { folder.appendingPathComponent($0).standardizedFileURL.path })
        return DispatchQueue.main.sync {
            NSDocumentController.shared.documents.contains {
                $0.isDocumentEdited && $0.fileURL.map { targets.contains($0.standardizedFileURL.path) } == true
            }
        }
    }

    private func otherMacName(_ message: String) -> String {
        message.components(separatedBy: "\n").first { $0.hasPrefix(Self.markerTrailer) }
            .map { String($0.dropFirst(Self.markerTrailer.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "another Mac"
    }

    static func conflictCopyName(for path: String, otherMac: String, in folder: URL) -> String {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().relativePath
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let safeMac = otherMac.replacingOccurrences(of: "/", with: "-")
        var number = 1
        while true {
            let suffix = number == 1 ? "" : " \(number)"
            let name = "\(base) (from \(safeMac)\(suffix))\(ext)"
            let relative = directory == "." || directory.isEmpty ? name : directory + "/" + name
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(relative).path) { return relative }
            number += 1
        }
    }

    static func hiddenBlocksAreValid(_ text: String) -> Bool {
        var remaining = text
        for name in ["coach", "outline", "annotations"] {
            let (body, contents) = HiddenBlock.extract(name, from: remaining)
            if let contents = contents,
               (try? JSONSerialization.jsonObject(with: Data(contents.utf8))) == nil { return false }
            remaining = body
        }
        // Merge markers or a stray block that no longer parses as a block.
        return !remaining.contains("<!-- laserfocus:") && !remaining.contains("\n<<<<<<< ")
    }

    private static func looksOffline(_ error: String) -> Bool {
        let lowered = error.lowercased()
        return ["could not resolve host", "unable to access", "network is unreachable", "timed out",
                "connection refused", "couldn't connect", "could not read from remote"].contains { lowered.contains($0) }
            && !lowered.contains("authentication") && !lowered.contains("403")
    }

    // MARK: Setup

    enum SetupError: LocalizedError {
        case gitMissing, folderNotEmpty(String), alreadyRepository(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .gitMissing:
                return "Git isn't installed. Install Apple's Command Line Tools (a window may have opened; otherwise run “xcode-select --install” in Terminal), then try again."
            case .folderNotEmpty(let path): return "“\(path)” already has files in it. Choose an empty or new folder."
            case .alreadyRepository(let path): return "“\(path)” is already a git repository. Choose another folder."
            case .failed(let message): return message
            }
        }
    }

    /// Creates a private GitHub repository and a library folder that syncs with it.
    func create(repositoryName: String, folder: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            let error = self.performCreate(repositoryName: repositoryName, folder: folder)
            DispatchQueue.main.async { self.finishSetup(error, completion: completion) }
        }
    }

    /// Downloads an existing library repository to a new folder.
    func connect(repository: String, folder: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            let error = self.performConnect(repository: repository, folder: folder)
            DispatchQueue.main.async { self.finishSetup(error, completion: completion) }
        }
    }

    /// Stops syncing. The folder and the GitHub repository stay as they are.
    func disconnect() {
        defaults.removeObject(forKey: Keys.folder)
        defaults.removeObject(forKey: Keys.repository)
        defaults.removeObject(forKey: Keys.lastSync)
        phase = .idle
    }

    private func finishSetup(_ error: Error?, completion: (Error?) -> Void) {
        if error == nil {
            CustomDictionary.shared.reloadFromLibrary()
            phase = .idle
            start()
        }
        completion(error)
    }

    private func performCreate(repositoryName: String, folder: URL) -> Error? {
        guard Git.isAvailable else { return SetupError.gitMissing }
        guard let token = GitHub.token()?.value else { return GitHub.Failure.noToken }
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) { return SetupError.alreadyRepository(folder.path) }
        do {
            let account = try GitHub.account(token: token)
            let fullName = try GitHub.createPrivateRepository(named: repositoryName, token: token)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            @discardableResult func git(_ arguments: String...) -> Git.Result { Git.run(arguments, in: folder, token: token) }
            for step in [git("init", "-q"), git("symbolic-ref", "HEAD", "refs/heads/main")] where !step.ok {
                return SetupError.failed(step.message)
            }
            configure(folder: folder, account: account, git: git)
            git("add", "-A")
            git("commit", "-q", "-m", "Start writing library\n\n\(Self.markerTrailer)\(macName)")
            git("remote", "add", "origin", "https://github.com/\(fullName).git")
            let push = git("push", "-q", "-u", "origin", "main")
            guard push.ok else { return SetupError.failed("The repository was created, but the first upload failed: \(push.message)") }
            save(folder: folder, repository: fullName)
            return nil
        } catch {
            return error
        }
    }

    private func performConnect(repository: String, folder: URL) -> Error? {
        guard Git.isAvailable else { return SetupError.gitMissing }
        guard let token = GitHub.token()?.value else { return GitHub.Failure.noToken }
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: folder.path), contents.contains(where: { !$0.hasPrefix(".") }) {
            return SetupError.folderNotEmpty(folder.path)
        }
        do {
            let account = try GitHub.account(token: token)
            try? fm.removeItem(at: folder)   // empty, or holding only hidden files
            try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let clone = Git.run(["clone", "-q", "https://github.com/\(repository).git", folder.path], in: nil,
                                token: token, timeout: 600)
            guard clone.ok else { return SetupError.failed("Couldn't download \(repository): \(clone.message)") }
            @discardableResult func git(_ arguments: String...) -> Git.Result { Git.run(arguments, in: folder, token: token) }
            if git("rev-parse", "--verify", "-q", "HEAD").ok == false {
                git("symbolic-ref", "HEAD", "refs/heads/main")   // empty repository
            }
            configure(folder: folder, account: account, git: git)
            git("add", "-A")
            if !git("status", "--porcelain").text.isEmpty {
                git("commit", "-q", "-m", "Set up LaserFocus on \(macName)\n\n\(Self.markerTrailer)\(macName)")
                git("push", "-q", "-u", "origin", "HEAD")
            }
            save(folder: folder, repository: repository)
            return nil
        } catch {
            return error
        }
    }

    /// Commit identity, ignore rules, and the shared dictionary file (merged with this Mac's words).
    private func configure(folder: URL, account: GitHub.Account, git: (String...) -> Git.Result) {
        _ = git("config", "user.name", account.name?.isEmpty == false ? account.name! : account.login)
        _ = git("config", "user.email", account.commitEmail)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try? ".DS_Store\n*~\n.~lock*\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        let dictionary = folder.appendingPathComponent(Self.dictionaryPath)
        try? FileManager.default.createDirectory(at: dictionary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: dictionary, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let local = DispatchQueue.main.sync { CustomDictionary.shared.words }
        let words = Set(existing + local).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        try? (words.joined(separator: "\n") + (words.isEmpty ? "" : "\n")).write(to: dictionary, atomically: true, encoding: .utf8)
    }

    private func save(folder: URL, repository: String) {
        defaults.set(folder.path, forKey: Keys.folder)
        defaults.set(repository, forKey: Keys.repository)
        lastSync = Date()
    }

    /// The library's dictionary file, when a library is set up.
    var dictionaryURL: URL? { folder?.appendingPathComponent(Self.dictionaryPath) }
}
