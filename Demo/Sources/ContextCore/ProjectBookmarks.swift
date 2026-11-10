import Foundation
import Darwin

public enum ProjectAccessError: LocalizedError {
    case authorizationRequired, moved, corrupt
    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: return L("请重新选择此项目文件夹以恢复访问权限。")
        case .moved: return L("项目文件夹的位置已改变，请重新添加项目。")
        case .corrupt: return L("项目授权记录损坏。原文件已保留，请恢复授权记录后重试。")
        }
    }
}

/// Owns exactly one explicit security-scope acquisition. Retain through asynchronous file work.
public final class ProjectAccessLease: @unchecked Sendable {
    public let url: URL
    private let scoped: Bool
    init(url: URL, scoped: Bool) { self.url = url; self.scoped = scoped }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

/// Separate from project metadata; bookmarks are private local capabilities, never exported.
public actor ProjectBookmarks {
    private let file: URL
    public init(file: URL) { self.file = file }
    private func records() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        do { return try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file)) }
        catch { throw ProjectAccessError.corrupt }
    }
    private func write(_ entries: [String: Data]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".bookmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try PrivateFile.writeNew(try JSONEncoder().encode(entries), to: temporary)
        guard rename(temporary.path, file.path) == 0 else { throw ProjectAccessError.corrupt }
    }
    public func acquire(_ requestedURL: URL, selected: Bool = false, required: Bool = true) throws -> ProjectAccessLease {
        let requested = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        // Direct access is only for local non-sandbox builds or the app's own container.
        guard required else { return ProjectAccessLease(url: requested, scoped: false) }
        var entries = try records()
        let url: URL
        var stale = false
        if selected { url = requestedURL }
        else {
            guard let data = entries[requested.path] else { throw ProjectAccessError.authorizationRequired }
            do { url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            catch { throw ProjectAccessError.authorizationRequired }
            guard url.standardizedFileURL.resolvingSymlinksInPath() == requested else { throw ProjectAccessError.moved }
        }
        // NSOpenPanel already starts implicit access. Transfer that acquisition to the lease;
        // restored bookmarks need an explicit, balanced start/stop pair.
        let scoped = selected || url.startAccessingSecurityScopedResource()
        guard scoped else { throw ProjectAccessError.authorizationRequired }
        let lease = ProjectAccessLease(url: url, scoped: scoped)
        if selected || stale {
            entries[requested.path] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            try write(entries)
        }
        return lease
    }
    public func forget(_ url: URL) throws {
        var entries = try records(); entries.removeValue(forKey: url.standardizedFileURL.resolvingSymlinksInPath().path)
        try write(entries)
    }
}
