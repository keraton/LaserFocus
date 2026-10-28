import AppKit

/// A Markdown (or plain text) file. NSDocument provides the standard Mac saving behaviour:
/// Save / Save As / Duplicate / Rename / Revert, autosave, Versions and Open Recent.
@objc(Document)
final class Document: NSDocument {
    private var loadedText = ""
    private weak var editor: EditorViewController?
    private let annotations = AnnotationStore()
    private let coach = CoachStore()
    private let writingOutline = WritingOutlineStore()

    override init() {
        super.init()
        annotations.onUserChange = { [weak self] in self?.updateChangeCount(.changeDone) }
        coach.onUserChange = { [weak self] in self?.updateChangeCount(.changeDone) }
        writingOutline.onUserChange = { [weak self] in self?.updateChangeCount(.changeDone) }
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let editor = EditorViewController(text: loadedText, annotations: annotations)
        self.editor = editor

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: EditorViewController.minimumWidth, height: 300)
        window.contentViewController = DocumentViewController(editor: editor, annotations: annotations,
                                                              writingOutline: writingOutline, coachStore: coach)
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.center()

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = true
        controller.windowFrameAutosaveName = "LaserFocusEditor"
        addWindowController(controller)
    }

    private var currentText: String {
        editor?.text ?? loadedText
    }

    override func data(ofType typeName: String) throws -> Data {
        editor?.textView.breakUndoCoalescing()
        let withNotes = annotations.fileText(body: currentText)
        return Data(coach.fileText(body: writingOutline.fileText(body: withNotes)).utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .macOSRoman)
        guard let decoded = text else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError)
        }
        // Hidden blocks sit at the end of the file: coach data last, the writing outline
        // before it, annotations before that.
        loadedText = annotations.load(fromFile: writingOutline.load(fromFile: coach.load(fromFile: decoded)))
        // Revert / external change: refresh the open editor.
        editor?.text = loadedText
    }

    // MARK: Writing library sync

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            // Saving happens often while typing; sync once the writer pauses.
            if error == nil && SyncLibrary.shared.contains(url) { SyncLibrary.shared.scheduleSync(after: 45) }
            completionHandler(error)
        }
    }

    override func showWindows() {
        super.showWindows()
        if SyncLibrary.shared.contains(fileURL) { SyncLibrary.shared.syncIfStale() }
    }

    override func close() {
        let inLibrary = SyncLibrary.shared.contains(fileURL)
        super.close()
        if inLibrary { SyncLibrary.shared.scheduleSync(after: 1) }
    }

    /// Moves (or, for a new document, saves) this document into the writing library.
    @objc func moveToLibrary(_ sender: Any?) {
        guard let folder = SyncLibrary.shared.folder else {
            SyncWindowController.shared.showWindow(sender)
            return
        }
        var name: String = fileURL?.lastPathComponent ?? displayName ?? "Untitled"
        if (name as NSString).pathExtension.isEmpty { name += ".md" }
        var destination = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (name as NSString).deletingPathExtension
            destination = folder.appendingPathComponent("\(base) \(number).\((name as NSString).pathExtension)")
            number += 1
        }
        let done: (Error?) -> Void = { [weak self] error in
            if let error = error {
                self?.presentError(error)
            } else {
                SyncLibrary.shared.scheduleSync(after: 2)
            }
        }
        if fileURL == nil {
            save(to: destination, ofType: fileType ?? "net.daringfireball.markdown", for: .saveAsOperation, completionHandler: done)
        } else {
            move(to: destination, completionHandler: done)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(moveToLibrary(_:)) {
            return !SyncLibrary.shared.isConfigured || !SyncLibrary.shared.contains(fileURL)
        }
        return super.validateUserInterfaceItem(item)
    }

    // Save as Markdown without the file-format popup.
    override var shouldRunSavePanelWithAccessoryView: Bool { false }
}
