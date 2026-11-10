import Foundation
import MiaoYanCore

public struct ProjectFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int
    public let modified: Date
    public let created: Date
    public init(path: String, size: Int, modified: Date, created: Date? = nil) {
        self.path = path; self.size = size; self.modified = modified; self.created = created ?? modified
    }
    public var name: String { (path as NSString).lastPathComponent }
    public var ext: String { (name as NSString).pathExtension.lowercased() }
    public var isEnvironment: Bool { Self.environmentName(name) }
    public var isMarkdown: Bool { ["md", "markdown", "mdown"].contains(ext) }
    public var convertible: Bool { ["pdf", "docx", "xlsx", "pptx", "png", "jpg", "jpeg", "heic", "tiff", "bmp"].contains(ext) }
    private static let textExtensions: Set<String> = [
        "md", "markdown", "mdown", "txt", "log", "json", "jsonc", "json5", "yaml", "yml", "toml",
        "ini", "conf", "config", "cfg", "properties", "xml", "csv", "tsv", "gitignore", "example",
        "swift", "py", "js", "ts", "tsx", "jsx", "css", "scss", "less", "html", "sh", "bash", "zsh",
        "rs", "go", "sql", "c", "h", "cpp", "hpp", "java", "kt", "kts", "dart", "vue", "svelte", "rb", "php",
    ]
    public var isText: Bool {
        isEnvironment || Self.textExtensions.contains(ext) || ["Dockerfile", "Makefile", "LICENSE", "NOTICE"].contains(name)
    }
    public var isEditableText: Bool { isText && !isEnvironment }
    public static func environmentName(_ name: String) -> Bool {
        name == ".env" || name.hasPrefix(".env.") || name == "env" || name.hasSuffix(".env")
    }
}

public enum WorkspaceError: LocalizedError {
    case outsideProject, tooLarge, unsupported, unreadable, empty, limit(String)
    public var errorDescription: String? {
        switch self {
        case .outsideProject: return L("文件已移出项目，或路径包含符号链接。请刷新项目后重新选择。")
        case .tooLarge: return L("文件超过 Demo 的读取上限。文本限 2 MB，转换源文件限 50 MB。")
        case .unsupported: return L("Demo 暂不支持此格式。Office 文件请使用 .docx、.xlsx、.pptx。")
        case .unreadable: return L("文件无法读取，请检查格式、权限或是否已加密。")
        case .empty: return L("未提取到可用文字。请检查文件内容或扫描清晰度。")
        case .limit(let message): return message
        }
    }
}

public struct ScanResult: Sendable {
    public let files: [ProjectFile]
    public let truncated: Bool
    public let directories: [String]
}

public enum ProjectFiles {
    static let excluded: Set<String> = ["node_modules", ".git", ".build", ".venv", "venv", "Pods", "DerivedData", "dist", "build", ".next", ".idea", ".DS_Store"]
    public static func blocked(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "mobileprovision"].contains((n as NSString).pathExtension)
            || ["id_rsa", "id_ed25519", "credentials", ".netrc", ".npmrc", ".pypirc"].contains(n)
    }
    /// Read parent levels before descending so one large child cannot hide its siblings.
    public static func scan(_ root: URL, maxFiles: Int = ScanCapacity.maximum.maxFiles, maxEntries: Int = ScanCapacity.maximum.maxEntries) throws -> ScanResult {
        guard maxFiles > 0, maxEntries > 0 else { throw WorkspaceError.unreadable }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var queue = [root], index = 0, examined = 0
        var files: [ProjectFile] = [], directories: [String] = []
        var truncated = false
        while index < queue.count {
            try Task.checkCancellation()
            let directory = queue[index]; index += 1
            // Re-check queued paths: a directory could have become a symbolic link since discovery.
            if directory != root {
                let relative = String(directory.path.dropFirst(prefix.count))
                do { _ = try checkedURL(root: root, path: relative) } catch { truncated = true; continue }
            }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch {
                if directory == root { throw WorkspaceError.unreadable }
                truncated = true; continue
            }
            for url in entries {
                try Task.checkCancellation()
                guard examined < maxEntries else { return ScanResult(files: sorted(files), truncated: true, directories: directories) }
                examined += 1
                let name = url.lastPathComponent
                if excluded.contains(name) || blocked(name) || (name.hasPrefix(".") && !ProjectFile.environmentName(name) && name != ".gitignore") { continue }
                guard let info = try? url.resourceValues(forKeys: keys) else { truncated = true; continue }
                if info.isSymbolicLink == true { continue }
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(prefix) else { throw WorkspaceError.outsideProject }
                let path = String(canonical.dropFirst(prefix.count))
                if info.isDirectory == true {
                    directories.append(path)
                    if info.isPackage != true { queue.append(URL(fileURLWithPath: canonical, isDirectory: true)) }
                } else if info.isRegularFile == true {
                    if files.count < maxFiles {
                        files.append(ProjectFile(path: path, size: info.fileSize ?? 0, modified: info.contentModificationDate ?? .distantPast, created: info.creationDate))
                    } else {
                        truncated = true
                    }
                }
            }
        }
        return ScanResult(files: sorted(files), truncated: truncated, directories: directories)
    }
    static func sorted(_ files: [ProjectFile]) -> [ProjectFile] {
        files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    public static func checkedURL(root: URL, path: String) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw WorkspaceError.outsideProject }
        var candidate = base
        for part in path.split(separator: "/") {
            guard !blocked(String(part)) else { throw WorkspaceError.outsideProject }
            candidate.appendPathComponent(String(part))
            let attributes = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true else { throw WorkspaceError.outsideProject }
        }
        let final = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard final.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else { throw WorkspaceError.outsideProject }
        return final
    }
    public static func text(root: URL, file: ProjectFile) throws -> RedactedText {
        let url = try checkedURL(root: root, path: file.path)
        guard file.isText else { throw WorkspaceError.unsupported }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 2_000_000 else { throw WorkspaceError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw WorkspaceError.tooLarge }
        guard let text = NoteText.decode(data), !text.contains("\0") else { throw WorkspaceError.unreadable }
        return SecretRedactor.redact(text, environment: file.isEnvironment)
    }
}

public struct RedactedText: Sendable {
    public let text: String
    public let count: Int
}

public enum SecretRedactor {
    public static func redact(_ text: String, environment: Bool = false) -> RedactedText {
        var count = 0
        var output: [String] = []
        var privateKey = false
        let sensitive = #"(?i)(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization|database[_-]?url|dsn|credential)"#
        for line in text.components(separatedBy: .newlines) {
            if line.contains("-----BEGIN") && line.contains("PRIVATE KEY") { privateKey = true; output.append("[PRIVATE KEY REDACTED]"); count += 1; continue }
            if privateKey { if line.contains("-----END") { privateKey = false }; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if environment {
                if trimmed.isEmpty { output.append(""); continue }
                // Comments may themselves contain copied credentials: do not export them.
                guard !trimmed.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { output.append(L("# [环境文件说明已隐藏]")); continue }
                let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
                guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { output.append(L("# [已隐藏非标准配置行]")); count += 1; continue }
                output.append("\(key)=[REDACTED]"); count += 1; continue
            }
            var value = line
            if let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                let prefix = String(line[..<separator])
                if prefix.range(of: sensitive, options: .regularExpression) != nil {
                    value = prefix + String(line[separator]) + " [REDACTED]"; count += 1
                }
            }
            // Also catch inline JSON/YAML fields, CLI flags, common bearer tokens and URL credentials.
            for pattern in [
                #"(?i)((?:password|passwd|secret|token|api[_-]?key|access[_-]?key|authorization)[\w-]*[\"']?\s*[:=]\s*)[^\s,;}]+"#,
                #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
                #"\bnva_[A-Za-z0-9_-]{43}\b"#,
                #"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{15,}|AKIA[A-Z0-9]{16})\b"#,
                #"(?i)([a-z][a-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@"#,
                #"(?i)([?&](?:token|key|secret|password|signature)=)[^\s&#]+"#,
            ] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(value.startIndex..., in: value)
                let matches = regex.numberOfMatches(in: value, range: range)
                if matches > 0 {
                    value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: regex.numberOfCaptureGroups > 0 ? "$1[REDACTED]" : "[REDACTED]")
                    count += matches
                }
            }
            output.append(value)
        }
        return RedactedText(text: output.joined(separator: "\n"), count: count)
    }
}
