import Foundation
import AppKit
import Combine

/// Sort key for the note list.
enum SortKey: String, CaseIterable, Identifiable {
    case created
    case name

    var id: String { rawValue }
    var label: String {
        switch self {
        case .created: return "作成日"
        case .name: return "名前"
        }
    }
}

/// User-facing preferences, backed by UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private enum Key {
        static let webhookURL = "webhookURL"
        static let enterToSend = "enterToSend"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let rootBookmark = "rootBookmark"
        static let lastOpenNote = "lastOpenNote"
        static let expandedFolders = "expandedFolders"
        static let sidebarVisible = "sidebarVisible"
        static let lastCursor = "lastCursor"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enterToSend: true,
            Key.fontSize: 0.0,
            Key.sortKey: SortKey.created.rawValue,
            Key.sortAscending: false,
            Key.sidebarVisible: true,
        ])
    }

    // MARK: Slack

    @Published var webhookURL: String = "" { didSet { defaults.set(webhookURL, forKey: Key.webhookURL) } }

    var webhookURLValue: URL? {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    var isWebhookConfigured: Bool { webhookURLValue != nil }

    /// true: Enter sends, Shift+Enter newline. false: Enter newline, Cmd+Enter sends.
    @Published var enterToSend: Bool = true { didSet { defaults.set(enterToSend, forKey: Key.enterToSend) } }

    // MARK: Editor font

    @Published var fontName: String? { didSet { defaults.set(fontName, forKey: Key.fontName) } }
    @Published var fontSize: Double = 0 { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }

    /// The editor font. Falls back to the system font when unset.
    var editorFont: NSFont {
        let size = fontSize > 0 ? CGFloat(fontSize) : NSFont.systemFontSize
        if let name = fontName, let f = NSFont(name: name, size: size) {
            return f
        }
        return NSFont.systemFont(ofSize: size)
    }

    // MARK: Sort

    @Published var sortKey: SortKey = .created { didSet { defaults.set(sortKey.rawValue, forKey: Key.sortKey) } }
    @Published var sortAscending: Bool = false { didSet { defaults.set(sortAscending, forKey: Key.sortAscending) } }

    // MARK: Restore state

    var rootBookmark: Data? {
        get { defaults.data(forKey: Key.rootBookmark) }
        set { defaults.set(newValue, forKey: Key.rootBookmark) }
    }

    var lastOpenNote: String? {
        get { defaults.string(forKey: Key.lastOpenNote) }
        set { defaults.set(newValue, forKey: Key.lastOpenNote) }
    }

    var expandedFolders: [String] {
        get { defaults.stringArray(forKey: Key.expandedFolders) ?? [] }
        set { defaults.set(newValue, forKey: Key.expandedFolders) }
    }

    var sidebarVisible: Bool {
        get { defaults.bool(forKey: Key.sidebarVisible) }
        set { defaults.set(newValue, forKey: Key.sidebarVisible) }
    }

    var lastCursor: Int {
        get { defaults.integer(forKey: Key.lastCursor) }
        set { defaults.set(newValue, forKey: Key.lastCursor) }
    }

    /// Load @Published mirrors from defaults at launch.
    func load() {
        webhookURL = defaults.string(forKey: Key.webhookURL) ?? ""
        enterToSend = defaults.bool(forKey: Key.enterToSend)
        fontName = defaults.string(forKey: Key.fontName)
        fontSize = defaults.double(forKey: Key.fontSize)
        sortKey = SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .created
        sortAscending = defaults.bool(forKey: Key.sortAscending)
    }
}
