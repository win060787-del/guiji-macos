import Foundation

public enum FileDateField: String, CaseIterable, Sendable, Codable {
    case modified = "修改日期", created = "创建日期", opened = "打开日期"
    public func date(for file: ProjectFile, opened: [String: Date]) -> Date? {
        switch self {
        case .modified: return file.modified
        case .created: return file.created
        case .opened: return opened[file.path]
        }
    }
}

public enum FileAge: String, CaseIterable, Sendable, Codable {
    case all = "不限日期", sixMonths = "6 个月前", threeMonths = "3 个月前", oneMonth = "1 个月前"
    case oneWeek = "一周前", threeDays = "3 天前", oneDay = "1 天前"
    public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        let component: Calendar.Component, value: Int
        switch self {
        case .all: return nil
        case .sixMonths: component = .month; value = -6
        case .threeMonths: component = .month; value = -3
        case .oneMonth: component = .month; value = -1
        case .oneWeek: component = .day; value = -7
        case .threeDays: component = .day; value = -3
        case .oneDay: component = .day; value = -1
        }
        return calendar.date(byAdding: component, value: value, to: now)
    }
}

public enum FileFormat: String, CaseIterable, Sendable, Codable {
    case markdown = "Markdown", pdf = "PDF", word = "Word", spreadsheet = "Excel / CSV"
    case presentation = "PowerPoint", image = "图片", text = "文本", code = "代码", configuration = "配置 / ENV", other = "其他"
    public static func of(_ file: ProjectFile) -> Self {
        if file.isEnvironment { return .configuration }
        if file.isMarkdown { return .markdown }
        switch file.ext {
        case "pdf": return .pdf
        case "doc", "docx", "rtf", "odt": return .word
        case "xls", "xlsx", "csv", "tsv", "ods": return .spreadsheet
        case "ppt", "pptx", "odp", "key": return .presentation
        case "png", "jpg", "jpeg", "heic", "tiff", "tif", "bmp", "gif", "webp", "svg", "avif": return .image
        case "txt", "log": return .text
        case "json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "conf", "config", "cfg", "properties", "xml", "example", "gitignore": return .configuration
        case "swift", "py", "js", "ts", "tsx", "jsx", "css", "scss", "less", "html", "sh", "bash", "zsh", "rs", "go", "sql", "c", "h", "cpp", "hpp", "java", "kt", "kts", "dart", "vue", "svelte", "rb", "php": return .code
        default:
            if ["LICENSE", "NOTICE"].contains(file.name) { return .text }
            if ["Dockerfile", "Makefile", ".gitignore"].contains(file.name) { return .configuration }
            return .other
        }
    }
}

public enum FileSort: String, CaseIterable, Sendable, Codable {
    case name = "名称", opened = "打开日期", created = "创建日期", modified = "修改日期", size = "大小"
}

public struct BrowserFilter: Equatable, Sendable {
    public var age: FileAge = .all
    public var dateField: FileDateField = .modified
    public var formats: Set<FileFormat> = []
    public var sort: FileSort = .name
    public var ascending = true
    public init() {}
    public var isFiltering: Bool { age != .all || !formats.isEmpty }

    public func matches(_ file: ProjectFile, query: String = "", opened: [String: Date] = [:], now: Date = Date()) -> Bool {
        if !query.isEmpty && !file.path.localizedCaseInsensitiveContains(query) { return false }
        if !formats.isEmpty && !formats.contains(FileFormat.of(file)) { return false }
        if let cutoff = age.cutoff(now: now) {
            guard let date = dateField.date(for: file, opened: opened), date < cutoff else { return false }
        }
        return true
    }

    public func apply(_ files: [ProjectFile], query: String = "", opened: [String: Date] = [:], now: Date = Date(), calendar: Calendar = .current) -> [ProjectFile] {
        let cutoff = age.cutoff(now: now, calendar: calendar)
        return files.filter { file in
            if !query.isEmpty && !file.path.localizedCaseInsensitiveContains(query) { return false }
            if !formats.isEmpty && !formats.contains(FileFormat.of(file)) { return false }
            if let cutoff {
                guard let date = dateField.date(for: file, opened: opened), date < cutoff else { return false }
            }
            return true
        }.map { (file: $0, name: $0.name) }.sorted { left, right in
            let lhs = left.file, rhs = right.file
            func names() -> Bool {
                let comparison = left.name.localizedStandardCompare(right.name)
                if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
                return lhs.path < rhs.path
            }
            switch sort {
            case .name: return names()
            case .size:
                if lhs.size != rhs.size { return ascending ? lhs.size < rhs.size : lhs.size > rhs.size }
            case .opened, .created, .modified:
                let field: FileDateField = sort == .opened ? .opened : sort == .created ? .created : .modified
                let a = field.date(for: lhs, opened: opened), b = field.date(for: rhs, opened: opened)
                // Never-opened files stay last in either direction; no fabricated access dates.
                if a == nil && b != nil { return false }
                if a != nil && b == nil { return true }
                if let a, let b, a != b { return ascending ? a < b : a > b }
            }
            return names()
        }.map { $0.file }
    }
}

public struct ProjectFolder: Identifiable, Hashable, Sendable {
    public let path: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var parent: String { DirectoryIndex.parent(of: path) }
    public var depth: Int { max(0, path.split(separator: "/").count - 1) }
}

public struct DirectoryIndex: Sendable {
    public private(set) var children: [String: [ProjectFolder]] = [:]
    public private(set) var paths: Set<String> = []
    public init(directories: [String] = [], files: [ProjectFile] = []) {
        for path in directories + files.map({ Self.parent(of: $0.path) }) {
            var path = path
            while !path.isEmpty {
                guard paths.insert(path).inserted else { break }
                path = Self.parent(of: path)
            }
        }
        for path in paths { children[Self.parent(of: path), default: []].append(ProjectFolder(path: path)) }
        for key in children.keys { children[key]?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }
    public static func parent(of path: String) -> String {
        let components = path.split(separator: "/")
        return components.dropLast().joined(separator: "/")
    }
    public static func contains(_ file: ProjectFile, in folder: String, recursively: Bool) -> Bool {
        if !recursively { return parent(of: file.path) == folder }
        return folder.isEmpty || file.path.hasPrefix(folder + "/")
    }
    public func visible(expanded: Set<String>) -> [ProjectFolder] {
        var result: [ProjectFolder] = []
        var stack = Array((children[""] ?? []).reversed())
        while let folder = stack.popLast() {
            result.append(folder)
            if expanded.contains(folder.path) { stack.append(contentsOf: (children[folder.path] ?? []).reversed()) }
        }
        return result
    }
}
