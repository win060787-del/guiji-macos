import Foundation

public struct WorkspaceLocation: Equatable, Sendable {
    public let path: String?
    public let section: String
    public let query: String
    public let folder: String
    public let filter: BrowserFilter

    public init(path: String?, section: String, query: String, folder: String = "", filter: BrowserFilter = BrowserFilter()) {
        self.path = path
        self.section = section
        self.query = query
        self.folder = folder
        self.filter = filter
    }
}

/// A project-scoped browser history. Filters belong to a visit so Back restores
/// the file list as well as the document. A new visit retires the forward branch.
public struct NavigationHistory<Location: Equatable & Sendable>: Sendable {
    private var entries: [Location] = []
    private var index = -1
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index + 1 < entries.count }
    public var current: Location? { entries.indices.contains(index) ? entries[index] : nil }

    public init() {}

    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(location)
        index = entries.count - 1
        if entries.count > 150 {
            entries.removeFirst(entries.count - 150)
            index = entries.count - 1
        }
    }

    public mutating func replaceCurrent(_ location: Location) {
        guard entries.indices.contains(index) else { return }
        entries[index] = location
    }

    public mutating func back() -> Location? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    public mutating func forward() -> Location? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    /// Drop removed files during refresh without moving the cursor to another
    /// project's data or silently making a forward page the current visit.
    public mutating func retain(where valid: (Location) -> Bool) {
        let precedingCount = entries.prefix(max(0, index)).filter(valid).count
        let currentSurvives = current.map(valid) ?? false
        entries = entries.filter(valid)
        if entries.isEmpty { index = -1 } else { index = min(entries.count - 1, currentSurvives ? precedingCount : max(0, precedingCount - 1)) }
    }
}
