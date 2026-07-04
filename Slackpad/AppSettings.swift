import Foundation
import AppKit
import Observation

/// Timestamp prepended to a post when it is appended to the note body.
enum PostTimestamp: String, CaseIterable, Identifiable {
    case time
    case dateTime
    case none

    var id: String { rawValue }
    var label: String {
        switch self {
        case .time: return "Time"
        case .dateTime: return "Date & time"
        case .none: return "None"
        }
    }
    /// DateFormatter pattern, or nil for no timestamp.
    var format: String? {
        switch self {
        case .time: return "HH:mm"
        case .dateTime: return "yyyy-MM-dd HH:mm"
        case .none: return nil
        }
    }
}

/// Sort key for the note list.
enum SortKey: String, CaseIterable, Identifiable {
    case created
    case name

    var id: String { rawValue }
    var label: String {
        switch self {
        case .created: return "Date Created"
        case .name: return "Name"
        }
    }
}

/// User-facing preferences, backed by UserDefaults.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private enum Key {
        static let webhookURL = "webhookURL"
        static let enterToSend = "enterToSend"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let postTimestamp = "postTimestamp"
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
            Key.postTimestamp: PostTimestamp.time.rawValue,
        ])
    }

    // MARK: Slack

    var webhookURL: String = "" { didSet { defaults.set(webhookURL, forKey: Key.webhookURL) } }

    var webhookURLValue: URL? {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    var isWebhookConfigured: Bool { webhookURLValue != nil }

    /// true: Enter sends, Shift+Enter newline. false: Enter newline, Cmd+Enter sends.
    var enterToSend: Bool = true { didSet { defaults.set(enterToSend, forKey: Key.enterToSend) } }

    /// Timestamp prepended when a post is appended to the note body.
    var postTimestamp: PostTimestamp = .time { didSet { defaults.set(postTimestamp.rawValue, forKey: Key.postTimestamp) } }

    // MARK: Editor font

    var fontName: String? { didSet { defaults.set(fontName, forKey: Key.fontName) } }
    var fontSize: Double = 0 { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }

    /// The editor font. Falls back to the system font when unset.
    var editorFont: NSFont {
        let size = fontSize > 0 ? CGFloat(fontSize) : NSFont.systemFontSize
        if let name = fontName, let f = NSFont(name: name, size: size) {
            return f
        }
        return NSFont.systemFont(ofSize: size)
    }

    // MARK: Sort

    var sortKey: SortKey = .created { didSet { defaults.set(sortKey.rawValue, forKey: Key.sortKey) } }
    var sortAscending: Bool = false { didSet { defaults.set(sortAscending, forKey: Key.sortAscending) } }

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

    /// Load observable properties from defaults at launch.
    func load() {
        webhookURL = defaults.string(forKey: Key.webhookURL) ?? ""
        enterToSend = defaults.bool(forKey: Key.enterToSend)
        fontName = defaults.string(forKey: Key.fontName)
        fontSize = defaults.double(forKey: Key.fontSize)
        sortKey = SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .created
        sortAscending = defaults.bool(forKey: Key.sortAscending)
        postTimestamp = PostTimestamp(rawValue: defaults.string(forKey: Key.postTimestamp) ?? "") ?? .time
    }
}
