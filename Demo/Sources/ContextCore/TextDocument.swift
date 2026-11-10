import Foundation

public enum TextEditError: LocalizedError {
    case unsupportedEncoding, conflict
    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: return L("此文件不是 UTF-8 文本，暂不支持编辑。")
        case .conflict: return L("文件已被其他应用修改，未覆盖磁盘内容。请保留草稿后重新打开。")
        }
    }
}

/// Keep the unredacted source separate from the redacted reader/export pipeline.
public struct TextDocument: Sendable {
    public let root: URL
    public let path: String
    public private(set) var original: Data
    public private(set) var savedText: String
    public var text: String
    private let bom: Bool
    public var isDirty: Bool { text != savedText }

    public init(root: URL, path: String) throws {
        let file = ProjectFile(path: path, size: 0, modified: .distantPast)
        guard file.isEditableText else { throw WorkspaceError.unsupported }
        let url = try ProjectFiles.checkedURL(root: root, path: path)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else { throw WorkspaceError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw WorkspaceError.tooLarge }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard let source = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8), !source.contains("\0") else { throw TextEditError.unsupportedEncoding }
        self.root = root; self.path = path; original = data
        savedText = source; text = source; self.bom = bom
    }

    public mutating func save() throws {
        guard isDirty else { return }
        let data = (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
        guard data.count <= 2_000_000 else { throw WorkspaceError.tooLarge }
        let url = try ProjectFiles.checkedURL(root: root, path: path)
        var coordinationError: NSError?
        var writeError: Error?
        let original = original
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                let checked = try ProjectFiles.checkedURL(root: root, path: path)
                guard checked == coordinated.standardizedFileURL.resolvingSymlinksInPath(), try Data(contentsOf: checked) == original else { throw TextEditError.conflict }
                try data.write(to: checked, options: .atomic)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        self.original = data; savedText = text
    }
}

// Source compatibility for the initial Markdown-only editor.
public typealias MarkdownDocument = TextDocument
public typealias MarkdownEditError = TextEditError
