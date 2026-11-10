import Foundation

/// Build once on a worker; views use lookups rather than traversing the complete project.
public struct BrowserIndex: Sendable {
    public let files: [ProjectFile]
    public let byPath: [String: ProjectFile]
    public let byParent: [String: [ProjectFile]]
    public let directories: DirectoryIndex
    public init(files: [ProjectFile] = [], directories: [String] = []) {
        self.files = files
        byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        byParent = Dictionary(grouping: files) { DirectoryIndex.parent(of: $0.path) }
        self.directories = DirectoryIndex(directories: directories, files: files)
    }
}
public struct BrowserRow: Identifiable, Sendable {
    public let id: String
    public let depth: Int
    public let folder: ProjectFolder?
    public let file: ProjectFile?
    public let containsFiles: Bool
    init(folder: ProjectFolder, containsFiles: Bool) {
        id = "folder:" + folder.path; depth = folder.depth; self.folder = folder; file = nil; self.containsFiles = containsFiles
    }
    init(file: ProjectFile, depth: Int) {
        id = "file:" + file.path; self.depth = depth; folder = nil; self.file = file; containsFiles = false
    }
}
public struct BrowserSnapshot: Sendable {
    public static let pageSize = 200
    public var rows: [BrowserRow] = []
    public var page = 0
    public var hasNext = false
    public init() {}
    public static func make(
        index: BrowserIndex, filter: BrowserFilter, query: String, folder: String,
        fixed: Bool, pins: Set<String>, expanded: Set<String>, opened: [String: Date], page: Int
    ) throws -> Self {
        try Task.checkCancellation()
        var result = Self(); result.page = max(0, page)
        let flat = fixed || !query.isEmpty || filter.isFiltering
        if flat {
            let candidates = index.files.filter { file in
                (fixed ? pins.contains(file.path) : DirectoryIndex.contains(file, in: folder, recursively: true))
            }
            let files = filter.apply(candidates, query: query, opened: opened)
            try Task.checkCancellation()
            result.page = min(result.page, max(0, (files.count - 1) / pageSize))
            let start = result.page * pageSize, end = min(start + pageSize, files.count)
            result.rows = files[start..<end].map { BrowserRow(file: $0, depth: 0) }
            result.hasNext = end < files.count
            return result
        }
        let start = result.page * pageSize
        var visited = 0
        func append(_ row: BrowserRow) -> Bool {
            defer { visited += 1 }
            if visited < start { return true }
            if result.rows.count == pageSize { result.hasNext = true; return false }
            result.rows.append(row); return true
        }
        func walk(_ path: String, depth: Int) throws -> Bool {
            try Task.checkCancellation()
            for child in index.directories.children[path] ?? [] {
                guard append(BrowserRow(folder: child, containsFiles: !(index.byParent[child.path] ?? []).isEmpty)) else { return false }
                if expanded.contains(child.path), try !walk(child.path, depth: depth + 1) { return false }
            }
            let children = filter.apply(index.byParent[path] ?? [], opened: opened)
            try Task.checkCancellation()
            for file in children { if !append(BrowserRow(file: file, depth: depth)) { return false } }
            return true
        }
        _ = try walk("", depth: 0)
        if result.rows.isEmpty && result.page > 0 {
            return try make(index: index, filter: filter, query: query, folder: folder, fixed: fixed, pins: pins, expanded: expanded, opened: opened, page: 0)
        }
        return result
    }
}
