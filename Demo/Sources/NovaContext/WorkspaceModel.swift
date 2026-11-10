import AppKit
import SwiftUI
import CryptoKit
import ContextCore

enum WorkspaceSection: String, CaseIterable {
    case all = "项目文件", fixed = "常用文件"
    var icon: String {
        switch self {
        case .all: return "folder";
        case .fixed: return "pin";
        }
    }
}

@MainActor final class WorkspaceModel: ObservableObject {
    private let dataDirectory: URL?
    init(dataDirectory: URL? = nil) { self.dataDirectory = dataDirectory }
    private var activeAccess: ProjectAccessLease?
    private lazy var bookmarks = dataDirectory == nil ? ProjectAccessPolicy.bookmarks : ProjectBookmarks(file: appData.appendingPathComponent("Access/bookmarks.json"))
    @Published var root: URL?
    @Published private(set) var isExternalDocument = false
    @Published private(set) var browserIndex = BrowserIndex() { didSet { requestBrowserUpdate(resetPage: false) } }
    var files: [ProjectFile] { browserIndex.files }
    var directoryIndex: DirectoryIndex { browserIndex.directories }
    @Published private(set) var browserSnapshot = BrowserSnapshot()
    @Published private(set) var browserPreparing = false
    private var browserPage = 0
    private var browserTask: Task<Void, Never>?
    private var browserWorker: Task<BrowserSnapshot, Error>?
    func changeBrowserPage(_ delta: Int) {
        guard !browserPreparing else { return }
        browserPage = max(0, browserSnapshot.page + delta)
        requestBrowserUpdate(resetPage: false)
    }
    private func requestBrowserUpdate(resetPage: Bool = true) {
        if resetPage { browserPage = 0 }
        browserTask?.cancel(); browserWorker?.cancel()
        guard !files.isEmpty || !directoryIndex.paths.isEmpty else {
            browserSnapshot = BrowserSnapshot(); browserPreparing = false; return
        }
        browserPreparing = true
        let index = browserIndex, filter = browserFilter, query = query, folder = folder
        let fixed = section == .fixed, pins = pins, expanded = expandedFolders, opened = lastOpened, page = browserPage
        browserTask = Task { [scope = activeAccess] in
            defer { withExtendedLifetime(scope) {} }
            do {
                try await Task.sleep(for: .milliseconds(query.isEmpty ? 25 : 180))
                let worker = Task.detached(priority: .userInitiated) {
                    try BrowserSnapshot.make(
                        index: index, filter: filter, query: query, folder: folder,
                        fixed: fixed, pins: pins, expanded: expanded, opened: opened, page: page)
                }
                browserWorker = worker
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                browserSnapshot = result; browserPage = result.page; browserPreparing = false
            } catch {
                if !Task.isCancelled { browserPreparing = false }
            }
        }
    }
    @Published var selection: String?
    @Published var section: WorkspaceSection = .all { didSet { requestBrowserUpdate() } }
    @Published var query = "" { didSet { requestBrowserUpdate() } }
    @Published var folder = "" { didSet { requestBrowserUpdate() } }
    @Published var expandedFolders: Set<String> = [] { didSet { requestBrowserUpdate() } }
    @Published var projectTreeExpanded = true
    @Published var browserFilter = BrowserFilter() { didSet { requestBrowserUpdate() } }
    @Published var lastOpened: [String: Date] = [:] { didSet { if browserFilter.sort == .opened { requestBrowserUpdate(resetPage: false) } } }
    @Published var pins: Set<String> = [] { didSet { if section == .fixed { requestBrowserUpdate() } } }
    @Published var preview = ""
    @Published var editing = false
    @Published var document: TextDocument?
    @Published var saving = false
    @Published var editorLoading = false
    var isDirty: Bool { document?.isDirty ?? false }
    var documentURL: URL? {
        guard let root, let path = document?.path else { return nil }
        return root.appendingPathComponent(path)
    }
    var draft: String {
        get { document?.text ?? "" }
        set { document?.text = newValue }
    }
    func performAfterEdits(_ action: @escaping () -> Void, cancelled: @escaping () -> Void = {}) {
        guard !saving, !editorLoading else { cancelled(); return }
        guard isDirty else { action(); return }
        let alert = NSAlert()
        alert.messageText = L("保存对“\(document?.path.components(separatedBy: "/").last ?? L("文件"))”的更改？")
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("不保存"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { if await saveDocument() { action() } else { cancelled() } }
        case .alertThirdButtonReturn:
            if var document { document.text = document.savedText; self.document = document }
            if !editing { showReading() }
            action()
        default: cancelled()
        }
    }
    func beginEditing() {
        guard !saving, !busy, !previewBusy, !editorLoading, canEdit, let root, let file = current else { return }
        if document?.path == file.path { editing = true; return }
        editorLoading = true
        Task { [scope = activeAccess] in
            defer { withExtendedLifetime(scope) {} }
            defer { editorLoading = false }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try TextDocument(root: root, path: file.path) }.value
                guard selection == file.path, self.root == root else { return }
                document = loaded; editing = true
            } catch { message = error.localizedDescription }
        }
    }
    func showReading() {
        editing = false; previewVisible = false
        if let document {
            let result = SecretRedactor.redact(document.text)
            preview = result.text; redactions = result.count
        }
    }
    @discardableResult func saveDocument() async -> Bool {
        guard !saving, var snapshot = document else { return false }
        guard snapshot.isDirty else { return true }
        saving = true
        defer { saving = false }
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                var value = snapshot; try value.save(); return value
            }.value
            document = snapshot
            if let old = browserIndex.byPath[snapshot.path] {
                let replacement = ProjectFile(path: snapshot.path, size: snapshot.original.count, modified: Date(), created: old.created)
                let existing = files, directories = Array(directoryIndex.paths)
                browserIndex = await Task.detached(priority: .userInitiated) {
                    BrowserIndex(files: existing.map { $0.path == replacement.path ? replacement : $0 }, directories: directories)
                }.value
            }
            let result = SecretRedactor.redact(snapshot.text)
            preview = result.text; redactions = result.count
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @Published var redactions = 0
    @Published var busy = false
    @Published var previewBusy = false
    @Published var busyText = ""
    @Published var message: String?
    @Published var conversion: ConversionResult?
    @Published var showConversion = false
    @Published var scanLimited = false
    @Published private(set) var scanCapacity = ScanCapacity.load()
    func changeScanCapacity(_ capacity: ScanCapacity) {
        guard !busy, capacity != scanCapacity else { return }
        performAfterEdits {
            self.scanCapacity = capacity
            UserDefaults.standard.set(capacity.rawValue, forKey: "indexCapacity")
            if let root = self.root { self.loadResolved(root) }
        }
    }
    private var loadedFolderScopes: Set<String> = []
    private var completeFolderScopes: Set<String> = []
    func folderNeedsLoading(_ path: String) -> Bool {
        scanLimited && !path.isEmpty && !loadedFolderScopes.contains(path)
            && !completeFolderScopes.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
    }
    private func loadFolderIfNeeded(_ path: String) {
        guard !busy, folderNeedsLoading(path), let root else { return }
        let capacity = scanCapacity
        busy = true; busyText = L("正在读取文件夹…")
        Task { [scope = activeAccess] in
            defer { withExtendedLifetime(scope) {} }
            defer { busy = false }
            do {
                let scan = try await Task.detached(priority: .userInitiated) {
                    let directory = try ProjectFiles.checkedURL(root: root, path: path)
                    let result = try ProjectFiles.scan(directory, maxFiles: capacity.maxFiles, maxEntries: capacity.maxEntries)
                    _ = try ProjectFiles.checkedURL(root: root, path: path)
                    return result
                }.value
                guard self.root == root else { return }
                let prefix = path + "/"
                let existing = browserIndex
                browserIndex = await Task.detached(priority: .userInitiated) {
                    var indexed = existing.byPath
                    for file in scan.files {
                        let rebased = prefix + file.path
                        indexed[rebased] = ProjectFile(path: rebased, size: file.size, modified: file.modified, created: file.created)
                    }
                    return BrowserIndex(files: Array(indexed.values), directories: Array(existing.directories.paths) + scan.directories.map { prefix + $0 })
                }.value
                loadedFolderScopes.insert(path)
                if !scan.truncated { completeFolderScopes.insert(path) }
                if folder == path && selection == nil, let first = firstScopedFile() { selectResolved(first.path, recordingHistory: false) }
                persist()
            } catch { message = L("文件夹读取失败：\(error.localizedDescription)") }
        }
    }
    @Published var previewVisible = false
    var canShowSplitPreview: Bool { editing && current?.isMarkdown == true && document?.path == selection }
    func toggleSplitPreview() {
        guard canShowSplitPreview, !isFullScreen else { return }
        previewVisible.toggle()
    }
    @Published var isFullScreen = false
    weak var window: NSWindow?
    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    @Published var sidebarVisible = true
    @Published private(set) var navigation = NavigationHistory<WorkspaceLocation>()
    private var previewTask: Task<Void, Never>?
    private var canPersist = true
    private var persistenceTask: Task<Void, Never>?

    var canEdit: Bool { current.map { $0.isEditableText } ?? false }
    var current: ProjectFile? { selection.flatMap { browserIndex.byPath[$0] } }
    var canGoBack: Bool { navigation.canGoBack && !busy }
    var canGoForward: Bool { navigation.canGoForward && !busy }
    private var location: WorkspaceLocation {
        WorkspaceLocation(path: selection, section: section.rawValue, query: query, folder: folder, filter: browserFilter)
    }
    var recursiveListing: Bool { !query.isEmpty || browserFilter.isFiltering }
    private func firstScopedFile(preferReadme: Bool = false) -> ProjectFile? {
        let candidates = section == .fixed || recursiveListing ? files : browserIndex.byParent[folder] ?? []
        let valid: (ProjectFile) -> Bool = { file in
            (self.section != .fixed || self.pins.contains(file.path))
                && (self.section != .all || DirectoryIndex.contains(file, in: self.folder, recursively: self.recursiveListing))
                && self.browserFilter.matches(file, query: self.query, opened: self.lastOpened)
        }
        if preferReadme, let readme = candidates.first(where: { $0.name.lowercased() == "readme.md" && valid($0) }) { return readme }
        return candidates.first(where: valid)
    }
    var visibleFolders: [ProjectFolder] { directoryIndex.visible(expanded: expandedFolders) }
    var childFolders: [ProjectFolder] {
        section == .all && !recursiveListing ? directoryIndex.children[folder] ?? [] : []
    }
    var browserTitle: String { section == .all && !folder.isEmpty ? (folder as NSString).lastPathComponent : L10n.text(section.rawValue) }
    var activeFilterCount: Int { (browserFilter.age == .all ? 0 : 1) + browserFilter.formats.count }
    func toggleFolder(_ path: String) {
        guard !busy else { return }
        if expandedFolders.contains(path) { expandedFolders.remove(path) } else { expandedFolders.insert(path) }
        persist()
        if expandedFolders.contains(path) { loadFolderIfNeeded(path) }
    }
    func openFolder(_ path: String) {
        guard path.isEmpty || directoryIndex.paths.contains(path) else { return }
        performAfterEdits {
            self.navigation.replaceCurrent(self.location)
            self.section = .all; self.folder = path
            var ancestor = path
            while !ancestor.isEmpty { self.expandedFolders.insert(ancestor); ancestor = DirectoryIndex.parent(of: ancestor) }
            self.projectTreeExpanded = true
            if let first = self.firstScopedFile() { self.selectResolved(first.path, recordingHistory: false) } else { self.clearDocument() }
            self.navigation.visit(self.location)
            self.persist()
            self.loadFolderIfNeeded(path)
        }
    }
    private func clearDocument() {
        document = nil; editing = false; previewVisible = false; previewTask?.cancel(); selection = nil; preview = ""; redactions = 0; previewBusy = false
    }
    var appData: URL {
        if let dataDirectory { return dataDirectory }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NovaContextDemo", isDirectory: true)
    }
    func configURL(_ root: URL) -> URL {
        let hash = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return appData.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(hash + ".json")
    }
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = L("打开 AI 开发项目")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { load(url, selected: true) }
    }
    /// Finder grants access to this file, not its siblings or the enclosing project.
    func openExternalFile(_ url: URL) async {
        guard url.isFileURL, !busy else { return }
        let allowed = await withCheckedContinuation { continuation in
            performAfterEdits({ continuation.resume(returning: true) },
                              cancelled: { continuation.resume(returning: false) })
        }
        guard allowed else { return }
        busy = true
        defer { busy = false }
        do {
            let lease = try await bookmarks.acquire(url, selected: true, required: ProjectAccessPolicy.needsBookmark(url))
            let file = try await Task.detached(priority: .userInitiated) {
                let values = try lease.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
                guard values.isRegularFile == true else { throw WorkspaceError.unsupported }
                let file = ProjectFile(path: lease.url.lastPathComponent, size: values.fileSize ?? 0,
                                       modified: values.contentModificationDate ?? Date(), created: values.creationDate)
                guard file.isText, !ProjectFiles.blocked(file.name) else { throw WorkspaceError.unsupported }
                _ = try ProjectFiles.text(root: lease.url.deletingLastPathComponent(), file: file)
                return file
            }.value
            if root != nil { persist() }
            previewTask?.cancel()
            activeAccess = lease
            isExternalDocument = true
            root = lease.url.deletingLastPathComponent()
            canPersist = false
            document = nil; selection = nil; editing = false; preview = ""
            folder = ""; query = ""; section = .all; browserFilter = BrowserFilter()
            pins = []; expandedFolders = []; lastOpened = [:]; navigation = NavigationHistory()
            loadedFolderScopes = []; completeFolderScopes = []; scanLimited = false
            browserIndex = BrowserIndex(files: [file])
            selectResolved(file.path)
        } catch { message = error.localizedDescription }
    }
    func load(_ url: URL, selected: Bool = false) {
        guard !busy else { return }
        performAfterEdits {
            self.busy = true; self.busyText = L("正在恢复项目权限…")
            Task { [scope = self.activeAccess] in
            defer { withExtendedLifetime(scope) {} }
                do {
                    let lease = try await self.bookmarks.acquire(url, selected: selected, required: ProjectAccessPolicy.needsBookmark(url))
                    self.busy = false
                    self.loadResolved(lease.url, access: lease)
                } catch ProjectAccessError.authorizationRequired {
                    self.busy = false
                    let panel = NSOpenPanel(); panel.title = L("重新授权项目文件夹")
                    panel.message = L("请选择“\(url.lastPathComponent)”文件夹。")
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let choice = panel.url {
                        if choice.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
                            self.load(choice, selected: true)
                        } else { self.message = L("所选位置不是原项目。可使用添加项目导入其他文件夹。") }
                    }
                } catch { self.busy = false; self.message = error.localizedDescription }
            }
        }
    }
    private func loadResolved(_ url: URL, access: ProjectAccessLease? = nil) {
        guard !busy else { return }
        isExternalDocument = false
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        let previous = root == normalized ? location : nil
        if previous == nil { navigation = NavigationHistory() } else { navigation.replaceCurrent(location) }
        if root != nil { persist() }
        previewTask?.cancel()
        activeAccess = access
        root = normalized
        document = nil; editing = false
        selection = nil; preview = ""; browserIndex = BrowserIndex(); pins = []; query = ""; section = .all; previewVisible = false
        folder = ""; browserFilter = BrowserFilter(); lastOpened = [:]
        if previous == nil { expandedFolders = []; projectTreeExpanded = true }
        loadedFolderScopes = []; completeFolderScopes = []
        busy = true; busyText = L("正在读取项目目录…"); canPersist = false
        guard let root else { busy = false; return }
        let config = configURL(root)
        let capacity = scanCapacity
        let pendingPersistence = persistenceTask
        Task { [scope = activeAccess] in
            defer { withExtendedLifetime(scope) {} }
            await pendingPersistence?.value
            do {
                let (scan, preparedIndex) = try await Task.detached(priority: .userInitiated) {
                    let scan = try ProjectFiles.scan(root, maxFiles: capacity.maxFiles, maxEntries: capacity.maxEntries)
                    return (scan, BrowserIndex(files: scan.files, directories: scan.directories))
                }.value
                var preferences: ProjectPreferences?
                do {
                    preferences = try await Task.detached(priority: .userInitiated) { try ProjectPreferences.load(from: config) }.value
                    canPersist = true
                } catch { canPersist = false; message = L("项目配置读取失败。原配置已保留，本次修改不会覆盖它。") }
                browserIndex = preparedIndex; scanLimited = scan.truncated
                completeFolderScopes = scan.truncated ? [] : [""]
                lastOpened = preferences?.lastOpened ?? [:]
                if previous == nil { expandedFolders = preferences?.expandedFolders ?? [] }
                expandedFolders.formIntersection(directoryIndex.paths)
                pins = preferences?.pins ?? []
                busy = false
                if let previous {
                    section = WorkspaceSection(rawValue: previous.section) ?? .all
                    query = previous.query
                    folder = directoryIndex.paths.contains(previous.folder) ? previous.folder : ""
                    browserFilter = previous.filter
                    let validPaths = Set(files.map(\.path))
                    navigation.retain { ($0.path.map { validPaths.contains($0) } ?? true) && ($0.folder.isEmpty || self.directoryIndex.paths.contains($0.folder)) }
                    selection = previous.path.flatMap { validPaths.contains($0) ? $0 : nil } ?? firstScopedFile()?.path
                } else {
                    selection = firstScopedFile(preferReadme: true)?.path
                }
                if let selection { select(selection, recordingHistory: false) }
                if previous == nil { navigation.visit(location) } else if navigation.current != nil { navigation.replaceCurrent(location) } else { navigation.visit(location) }
                if preferences == nil { persist() }
            } catch { busy = false; message = error.localizedDescription }
        }
    }
    func refresh() {
        guard let root, !busy else { return }
        persist(); load(root)
    }
    func select(_ path: String, recordingHistory: Bool = true) {
        guard path != selection || document == nil else { return }
        performAfterEdits { self.selectResolved(path, recordingHistory: recordingHistory) }
    }
    private func selectResolved(_ path: String, recordingHistory: Bool = true) {
        guard browserIndex.byPath[path] != nil else { return }
        if recordingHistory { navigation.replaceCurrent(location) }
        document = nil; editing = false
        selection = path; previewVisible = false; preview = ""; redactions = 0
        lastOpened[path] = Date(); persist()
        previewBusy = false
        if recordingHistory { navigation.visit(location) }
        previewTask?.cancel()
        guard let root, let file = current else { return }
        guard file.isText else { return }
        previewBusy = true
        previewTask = Task { [scope = activeAccess] in
            defer { withExtendedLifetime(scope) {} }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ProjectFiles.text(root: root, file: file) }.value
                guard !Task.isCancelled, selection == path else { return }
                preview = result.text; redactions = result.count; previewBusy = false
            } catch {
                guard !Task.isCancelled, selection == path else { return }
                preview = L("无法预览：\(error.localizedDescription)"); previewBusy = false
            }
        }
    }
    func navigate(to section: WorkspaceSection) {
        performAfterEdits { self.navigateResolved(to: section) }
    }
    private func navigateResolved(to section: WorkspaceSection) {
        guard !busy else { return }
        navigation.replaceCurrent(location)
        self.section = section
        if section == .all { folder = "" }
        if let first = firstScopedFile() {
            select(first.path, recordingHistory: false)
        } else {
            document = nil; editing = false; previewVisible = false; previewTask?.cancel(); selection = nil; preview = ""; redactions = 0; previewBusy = false
        }
        navigation.visit(location)
    }
    func goBack() {
        performAfterEdits { self.goBackResolved() }
    }
    private func goBackResolved() {
        guard canGoBack else { return }
        navigation.replaceCurrent(location)
        if let previous = navigation.back() { restore(previous) }
    }
    func goForward() {
        performAfterEdits { self.goForwardResolved() }
    }
    private func goForwardResolved() {
        guard canGoForward else { return }
        navigation.replaceCurrent(location)
        if let next = navigation.forward() { restore(next) }
    }
    private func restore(_ location: WorkspaceLocation) {
        section = WorkspaceSection(rawValue: location.section) ?? .all
        query = location.query
        folder = location.folder; browserFilter = location.filter
        var ancestor = folder
        while !ancestor.isEmpty { expandedFolders.insert(ancestor); ancestor = DirectoryIndex.parent(of: ancestor) }
        if let path = location.path { select(path, recordingHistory: false) } else { document = nil; editing = false; previewVisible = false; previewTask?.cancel(); selection = nil; preview = ""; redactions = 0; previewBusy = false }
    }
    func togglePin(_ file: ProjectFile) {
        if pins.contains(file.path) { pins.remove(file.path) } else { pins.insert(file.path) }
        persist()
    }
    func persist() {
        guard let root, canPersist else { return }
        let url = configURL(root)
        let preferences = ProjectPreferences(pins: pins, lastOpened: lastOpened, expandedFolders: expandedFolders)
        let previous = persistenceTask
        persistenceTask = Task { [scope = activeAccess] in
            defer { withExtendedLifetime(scope) {} }
            await previous?.value
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
                }.value
            } catch { if self.root == root { message = L("配置未保存：\(error.localizedDescription)") } }
        }
    }
    func flushPreferences() async {
        persist(); await persistenceTask?.value
    }
    func chooseConversion() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择要转换为 Markdown 的资料")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { convert(url) }
    }
    func convertFile(_ file: ProjectFile) {
        guard let root else { return }
        do { convert(try ProjectFiles.checkedURL(root: root, path: file.path)) } catch { message = error.localizedDescription }
    }
    func convert(_ url: URL) {
        guard !busy else { return }
        busy = true; busyText = L("正在本机转换 \(url.lastPathComponent)…")
        Task { [scope = activeAccess] in
            defer { withExtendedLifetime(scope) {} }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try DocumentConverter.convert(url) }.value
                conversion = result; busy = false; showConversion = true
            } catch { busy = false; message = error.localizedDescription }
        }
    }
    @discardableResult func saveMarkdown(_ content: String, name: String) -> Bool {
        let panel = NSSavePanel()
        panel.title = L("保存 Markdown")
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            // New files only: never overwrite a source document from the reader.
            try Data(content.utf8).write(to: url, options: .withoutOverwriting)
            return true
        } catch { message = L("未保存。请选择新的文件名，避免覆盖已有资料。\n\(error.localizedDescription)"); return false }
    }
    func saveConversion() {
        guard let conversion else { return }
        if saveMarkdown(conversion.markdown, name: (conversion.source as NSString).deletingPathExtension + "-converted.md") {
            showConversion = false; refresh()
        }
    }
    func openDemo() {
        performAfterEdits {
            guard !self.busy else { return }
            let language = L10n.language
            let useChineseSample = language == .simplifiedChinese || language == .traditionalChinese
            let destination = self.appData.appendingPathComponent(
                useChineseSample ? "Demo Project" : "Demo Project (English)", isDirectory: true
            )
            let resourceName = useChineseSample ? "SampleProject" : "SampleProjectEnglish"
            guard let bundled = Bundle.module.url(forResource: "Resources", withExtension: nil)?
                .appendingPathComponent(resourceName, isDirectory: true) else { return }
            self.busy = true; self.busyText = L("正在打开示例项目…")
            Task { [scope = self.activeAccess] in
            defer { withExtendedLifetime(scope) {} }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let manager = FileManager.default
                        if !manager.fileExists(atPath: destination.path) {
                            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try manager.copyItem(at: bundled, to: destination)
                            let template = destination.appendingPathComponent("env.example")
                            if manager.fileExists(atPath: template.path) { try manager.moveItem(at: template, to: destination.appendingPathComponent(".env.example")) }
                        }
                        let readme = destination.appendingPathComponent("README.md")
                        if let data = try? Data(contentsOf: readme), SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == "2fd6e0321c0e9c69b3ca0740b2ecaa477c1bcf57054c56b367fe24f087c2b329" {
                            try Data(contentsOf: bundled.appendingPathComponent("README.md")).write(to: readme, options: .atomic)
                        }
                        let references = bundled.appendingPathComponent("references", isDirectory: true)
                        if manager.fileExists(atPath: references.path) {
                            let outputDirectory = destination.appendingPathComponent("references", isDirectory: true)
                            try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                            for source in try manager.contentsOfDirectory(at: references, includingPropertiesForKeys: nil) {
                                let output = outputDirectory.appendingPathComponent(source.lastPathComponent)
                                if !manager.fileExists(atPath: output.path) { try manager.copyItem(at: source, to: output) }
                            }
                        }
                    }.value
                    self.busy = false; self.loadResolved(destination)
                } catch { self.busy = false; self.message = L("示例项目打开失败：\(error.localizedDescription)") }
            }
        }
    }
    func reveal() {
        guard let root, let file = current, let url = try? ProjectFiles.checkedURL(root: root, path: file.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
