import AppKit

enum ThemeChoice: String {
    case light, dark, system
}

enum FocusMode: Int {
    case off = 0, sentence, oneParagraph, twoParagraphs, threeParagraphs

    var title: String {
        switch self {
        case .off: return "Off"
        case .sentence: return "Sentence"
        case .oneParagraph: return "1 Paragraph"
        case .twoParagraphs: return "2 Paragraphs"
        case .threeParagraphs: return "3 Paragraphs"
        }
    }

    var paragraphCount: Int {
        switch self {
        case .oneParagraph: return 1
        case .twoParagraphs: return 2
        case .threeParagraphs: return 3
        default: return 0
        }
    }
}

enum FocusStyle: Int {
    case dim = 0, hide
}

enum SidebarTab: String {
    case outline, notes
}

enum FontStyle: String {
    case serif, sans, mono
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("LaserFocusSettingsChanged")
}

/// App-wide preferences, persisted in UserDefaults. Every change posts `.settingsChanged`
/// so all open editors restyle themselves.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "theme": ThemeChoice.system.rawValue,
            "focusMode": FocusMode.oneParagraph.rawValue,
            "focusStyle": FocusStyle.dim.rawValue,
            "grammarColors": false,
            "autocomplete": true,
            "typewriter": false,
            "showOutline": false,
            "sidebarTab": SidebarTab.outline.rawValue,
            "fontStyle": FontStyle.serif.rawValue,
            "fontSize": 18.0,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    var theme: ThemeChoice {
        get { ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "theme"); changed() }
    }

    var focusMode: FocusMode {
        get { FocusMode(rawValue: defaults.integer(forKey: "focusMode")) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "focusMode"); changed() }
    }

    var focusStyle: FocusStyle {
        get { FocusStyle(rawValue: defaults.integer(forKey: "focusStyle")) ?? .dim }
        set { defaults.set(newValue.rawValue, forKey: "focusStyle"); changed() }
    }

    var grammarColors: Bool {
        get { defaults.bool(forKey: "grammarColors") }
        set { defaults.set(newValue, forKey: "grammarColors"); changed() }
    }

    var autocomplete: Bool {
        get { defaults.bool(forKey: "autocomplete") }
        set { defaults.set(newValue, forKey: "autocomplete"); changed() }
    }

    var typewriter: Bool {
        get { defaults.bool(forKey: "typewriter") }
        set { defaults.set(newValue, forKey: "typewriter"); changed() }
    }

    var showSidebar: Bool {
        get { defaults.bool(forKey: "showOutline") }
        set { defaults.set(newValue, forKey: "showOutline"); changed() }
    }

    var sidebarTab: SidebarTab {
        get { SidebarTab(rawValue: defaults.string(forKey: "sidebarTab") ?? "") ?? .outline }
        set { defaults.set(newValue.rawValue, forKey: "sidebarTab"); changed() }
    }

    var fontStyle: FontStyle {
        get { FontStyle(rawValue: defaults.string(forKey: "fontStyle") ?? "") ?? .serif }
        set { defaults.set(newValue.rawValue, forKey: "fontStyle"); changed() }
    }

    var fontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "fontSize")) }
        set { defaults.set(Double(min(max(newValue, 10), 48)), forKey: "fontSize"); changed() }
    }

    /// True when the dark palette should be used, resolving "system" against the OS appearance.
    var isDark: Bool {
        switch theme {
        case .light: return false
        case .dark: return true
        case .system:
            if #available(macOS 10.14, *) {
                return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            return false
        }
    }

    var palette: Palette { isDark ? .dark : .light }

    func baseFont() -> NSFont {
        let size = fontSize
        switch fontStyle {
        case .serif:
            return NSFont(name: "Charter", size: size)
                ?? NSFont(name: "Georgia", size: size)
                ?? NSFont.systemFont(ofSize: size)
        case .sans:
            return NSFont.systemFont(ofSize: size)
        case .mono:
            return monoFont(size: size)
        }
    }

    func monoFont(size: CGFloat) -> NSFont {
        NSFont(name: "Menlo", size: size) ?? NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

struct Palette {
    let background: NSColor
    let sidebar: NSColor
    let text: NSColor
    let muted: NSColor
    let accent: NSColor
    let codeBackground: NSColor
    let selection: NSColor
    let caret: NSColor
    let subject: NSColor
    let predicate: NSColor
    let object: NSColor
    let modifier: NSColor
    let annotation: NSColor

    var dimmed: NSColor { text.withAlphaComponent(0.18) }
    var ghost: NSColor { text.withAlphaComponent(0.35) }

    static let light = Palette(
        background: NSColor(hex: 0xFAF9F6),
        sidebar: NSColor(hex: 0xF0EEE9),
        text: NSColor(hex: 0x2B2B2B),
        muted: NSColor(hex: 0x9A9A9A),
        accent: NSColor(hex: 0x1A7FD4),
        codeBackground: NSColor(hex: 0xEFEDE8),
        selection: NSColor(hex: 0xB9D7F5),
        caret: NSColor(hex: 0x1A9FFF),
        subject: NSColor(hex: 0x1F62C4),
        predicate: NSColor(hex: 0xC8323E),
        object: NSColor(hex: 0x1E8A5A),
        modifier: NSColor(hex: 0x8A4FC4),
        annotation: NSColor(hex: 0xF2B705)
    )

    static let dark = Palette(
        background: NSColor(hex: 0x1C1D20),
        sidebar: NSColor(hex: 0x161719),
        text: NSColor(hex: 0xDCDCDC),
        muted: NSColor(hex: 0x6F7277),
        accent: NSColor(hex: 0x5AB0F5),
        codeBackground: NSColor(hex: 0x2A2C30),
        selection: NSColor(hex: 0x2F4A66),
        caret: NSColor(hex: 0x1A9FFF),
        subject: NSColor(hex: 0x6CA8FF),
        predicate: NSColor(hex: 0xFF7A7F),
        object: NSColor(hex: 0x5CD49A),
        modifier: NSColor(hex: 0xC59BFF),
        annotation: NSColor(hex: 0xE5B53A)
    )
}
