import AppKit

/// A Markdown (or plain text) file. NSDocument provides the standard Mac saving behaviour:
/// Save / Save As / Duplicate / Rename / Revert, autosave, Versions and Open Recent.
@objc(Document)
final class Document: NSDocument {
    private var loadedText = ""
    private weak var editor: EditorViewController?
    private let annotations = AnnotationStore()

    override init() {
        super.init()
        annotations.onUserChange = { [weak self] in self?.updateChangeCount(.changeDone) }
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let editor = EditorViewController(text: loadedText, annotations: annotations)
        self.editor = editor

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 300)
        window.contentViewController = DocumentViewController(editor: editor, annotations: annotations)
        window.setContentSize(NSSize(width: 1000, height: 720))
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
        return Data(annotations.fileText(body: currentText).utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .macOSRoman)
        guard let decoded = text else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError)
        }
        loadedText = annotations.load(fromFile: decoded)
        // Revert / external change: refresh the open editor.
        editor?.text = loadedText
    }

    // Save as Markdown without the file-format popup.
    override var shouldRunSavePanelWithAccessoryView: Bool { false }
}
