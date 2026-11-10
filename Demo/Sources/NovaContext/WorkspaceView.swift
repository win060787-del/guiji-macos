import SwiftUI
import UniformTypeIdentifiers
import ContextCore

struct WorkspaceView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: WorkspaceModel
    @State private var dropTargeted = false
    @StateObject private var library: ProjectLibraryModel
    @StateObject private var services: LocalServicesModel
    @State private var showingProjects = true
    @State private var credentialProject: URL?
    @AppStorage("onboardingCompletedV1") private var onboardingCompleted = false
    @State private var showingOnboarding = false
    @State private var showingGuide: BundledGuide?
    @State private var onboardingDestination: OnboardingDestination?
    private let servicesReady: (LocalServicesModel) -> Void
    @ObservedObject var vault: CredentialVaultModel
    @AppStorage("appearance") private var appearance = "system"
    init(model: WorkspaceModel, vault: CredentialVaultModel, library: ProjectLibraryModel? = nil, showingProjects: Bool = true, servicesReady: @escaping (LocalServicesModel) -> Void = { _ in }) {
        self.model = model; self.vault = vault; self.servicesReady = servicesReady
        _showingProjects = State(initialValue: showingProjects)
        _library = StateObject(wrappedValue: library ?? ProjectLibraryModel())
        _services = StateObject(wrappedValue: LocalServicesModel(vault: vault.repository))
    }
    var body: some View {
        VStack(spacing: 0) {
            if showingProjects && !model.isFullScreen {
                ProjectCardsView(library: library, vault: vault, open: { card in
                    if model.root != card.url { model.load(card.url) }
                    if model.root == card.url {
                        showingProjects = false
                        Task { await library.visit(card.url); await library.inspect(card.url) }
                    }
                }, add: {
                    model.chooseProject()
                }, manageCredentials: { root in
                    credentialProject = root; vault.presented = true
                }, exportBrief: exportProjectBrief, manageAuthorizations: { root in
                    services.project = root.path; services.presented = true
                }, removeProject: { card in
                    guard await services.revokeProject(card.path) else {
                        model.message = services.error ?? L("服务正在处理，请稍后移除项目"); return
                    }
                    await library.remove(card)
                })
            } else {
                workspace
            }
            if !model.isFullScreen && (model.busy || model.saving || model.isDirty || model.scanLimited) {
                Divider()
                statusBar
            }
        }
        .background(FrostedPanel())
        .background(DocumentWindow(model: model, vault: vault, services: services).frame(width: 0, height: 0))
        .tint(Palette.accent)
        .toolbar(model.isFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { showingProjects.toggle() } label: {
                    Image(systemName: "square.grid.2x2").font(.system(size: 18)).frame(width: 30, height: 30)
                }.accessibilityLabel(showingProjects ? L("返回项目文件") : L("项目空间"))
                    .disabled(showingProjects && model.root == nil)
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium)).frame(width: 30, height: 30)
                }
                .disabled(!model.canGoBack).accessibilityLabel(L("后退"))
                Button {
                    model.goForward()
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 18, weight: .medium)).frame(width: 30, height: 30)
                }
                .disabled(!model.canGoForward).accessibilityLabel(L("前进"))
                Button {
                    model.sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 18, weight: .medium)).frame(width: 30, height: 30)
                }

                .accessibilityLabel(model.sidebarVisible ? L("隐藏项目侧栏") : L("显示项目侧栏"))
            }
            ToolbarItem(placement: .automatic) {
                Button { services.project = model.root?.path ?? ""; services.presented = true } label: {
                    Image(systemName: "server.rack").font(.system(size: 18)).frame(width: 30, height: 30)
                }.accessibilityLabel(L("本机服务与临时授权"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    credentialProject = model.root; vault.presented = true
                } label: {
                    Image(systemName: "key").font(.system(size: 18)).frame(width: 30, height: 30)
                }.accessibilityLabel(L("环境与凭证"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    if let card = library.cards.first(where: { $0.path == model.root?.path }) {
                        exportProjectBrief(card)
                    }
                } label: {
                    Image(systemName: "doc.badge.arrow.up").font(.system(size: 18)).frame(width: 30, height: 30)
                }.accessibilityLabel(L("导出 AI 项目说明"))
                    .disabled(model.root == nil || library.inspecting.contains(model.root?.path ?? "") || vault.busy)
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker(L("外观"), selection: $appearance) {
                        Text(L("跟随系统")).tag("system")
                        Text(L("浅色")).tag("light")
                        Text(L("深色")).tag("dark")
                    }
                    Divider()
                    LanguagePicker()
                } label: {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 18)).frame(width: 30, height: 30).accessibilityLabel(L("外观"))
                }.accessibilityLabel(L("外观"))
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(model.root?.lastPathComponent ?? L("归记")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }.accessibilityElement(children: .combine)
            }
        }
        .onAppear { servicesReady(services) }
        .onChange(of: locale.identifier) { _, _ in vault.syncReminders() }
        .onDisappear { model.persist() }
        .task {
            await library.load()
            if let root = model.root, !model.isExternalDocument { await library.visit(root); await library.inspect(root) }
            await vault.load()
            #if DEBUG
            let capture = ProcessInfo.processInfo.environment["NOVA_CAPTURE_STORE"] == "1"
            #else
            let capture = false
            #endif
            if !onboardingCompleted && !capture && !model.isExternalDocument { showingOnboarding = true }
        }
        .onChange(of: model.root) { _, root in
            guard let root else { return }
            showingProjects = false
            guard !model.isExternalDocument else { showingOnboarding = false; return }
            Task { await library.visit(root); await library.inspect(root) }
        }
        .onChange(of: model.selection) { _, path in
            if model.isExternalDocument && path != nil { showingProjects = false }
        }
        .onChange(of: vault.presented) { _, presented in
            if !presented { credentialProject = nil }
        }
        .onChange(of: library.error) { _, error in
            if let error { model.message = error; library.error = nil }
        }
        .onChange(of: vault.error) { _, error in
            if !vault.presented, let error { model.message = error; vault.error = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in services.shutdown() }
        .onReceive(NotificationCenter.default.publisher(for: AppHelp.onboarding)) { _ in showingOnboarding = true }
        .onReceive(NotificationCenter.default.publisher(for: AppHelp.manual)) { _ in showingGuide = .manual }
        .onReceive(NotificationCenter.default.publisher(for: AppHelp.privacy)) { _ in showingGuide = .privacy }
        .onReceive(NotificationCenter.default.publisher(for: AppHelp.terms)) { _ in showingGuide = .terms }
        .sheet(isPresented: $showingOnboarding, onDismiss: {
            guard let destination = onboardingDestination else { return }
            onboardingDestination = nil
            switch destination {
            case .workspace: showingProjects = model.root == nil
            case .credentials: credentialProject = model.root; vault.presented = true
            case .services: services.project = model.root?.path ?? ""; services.presented = true
            }
        }) {
            OnboardingView(model: model) { destination in
                onboardingCompleted = true; onboardingDestination = destination; showingOnboarding = false
            }
        }
        .sheet(item: $showingGuide) { UserGuideView(document: $0) }
        .sheet(isPresented: $services.presented) {
            LocalServicesView(services: services, vault: vault, projects: library.cards)
        }
        .sheet(isPresented: $vault.presented) {
            CredentialVaultView(vault: vault, project: credentialProject ?? model.root)
                .alert(L("环境与凭证"), isPresented: Binding(get: { vault.error != nil }, set: { if !$0 { vault.error = nil } })) {
                    Button(L("好")) { vault.error = nil }
                } message: {
                    Text(vault.error ?? "")
                }
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).stroke(Palette.accent, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if directory { model.load(url) } else { model.convert(url) }
                }
            }
            return true
        }
        .sheet(isPresented: $model.showConversion) { ConversionSheet(model: model) }
        .alert(L("归记"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("好")) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private func exportProjectBrief(_ card: ProjectCard) {
        let export = { library.exportBrief(card, credentials: vault.records) }
        if model.root?.path == card.path {
            model.performAfterEdits(export)
        } else { export() }
    }

    private var workspace: some View {
            HStack(spacing: 0) {
                if !model.isFullScreen {
                    if model.sidebarVisible {
                        sidebar.frame(width: 310)
                        Rectangle().fill(Palette.line).frame(width: 1)
                    }
                }
                reader.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button {
                model.chooseProject()
            } label: {
                HStack(spacing: 10) {
                    Image("BrandLogo", bundle: .module).resizable().scaledToFit()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    Text(model.root?.lastPathComponent ?? L("打开项目…"))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel(L("打开或切换项目"))
            if let root = model.root { ProjectCredentialTags(vault: vault, root: root) }
            HStack(spacing: 6) {
                ForEach(WorkspaceSection.allCases, id: \.self) { section in
                    Button {
                        model.navigate(to: section)
                    } label: {
                        Label(L10n.text(section.rawValue), systemImage: section.icon)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                model.section == section ? Palette.accent.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(model.section == section ? .isSelected : [])
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            fileList
        }.background(FrostedPanel())
            .accessibilityElement(children: .contain).accessibilityLabel(L("项目文件侧栏"))
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("搜索文件名或路径"), text: $model.query).textFieldStyle(.plain).font(.system(size: 13)).accessibilityLabel(L("搜索文件名或路径"))
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(WorkspaceIconStyle()).accessibilityLabel(L("清除搜索"))
                }
                BrowserOptionsMenu(model: model)
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(WorkspaceIconStyle()).accessibilityLabel(L("刷新项目文件")).disabled(model.busy)
            }.frame(minHeight: 36).padding(6).background(Palette.surface, in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12).padding(.bottom, 12)
            if model.section == .all { FolderLocationBar(model: model) }
            if model.browserFilter.isFiltering {
                HStack(spacing: 6) {
                    Text(filterSummary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        model.browserFilter.age = .all; model.browserFilter.formats = []
                    } label: {
                        Image(systemName: "xmark.circle").frame(width: 28, height: 28)
                    }.buttonStyle(.borderless).accessibilityLabel(L("清除筛选"))
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.browserSnapshot.rows) { entry in
                        if let folder = entry.folder {
                            FolderTreeRow(model: model, folder: folder, containsFiles: entry.containsFiles)
                        } else if let file = entry.file {
                            fileRow(file).padding(.leading, CGFloat(min(entry.depth, 5)) * 12)
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
                if model.browserSnapshot.rows.isEmpty && !model.busy && !model.browserPreparing {
                    Text(L("无文件")).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(18)
                }
            }
            .disabled(model.browserPreparing)
            if model.browserPreparing { ProgressView().controlSize(.small).padding(8) }
            if model.browserSnapshot.page > 0 || model.browserSnapshot.hasNext {
                HStack {
                    Button(L("上一页")) { model.changeBrowserPage(-1) }.disabled(model.browserSnapshot.page == 0 || model.browserPreparing)
                    Spacer()
                    Text(L("第 \(model.browserSnapshot.page + 1) 页")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("下一页")) { model.changeBrowserPage(1) }.disabled(!model.browserSnapshot.hasNext || model.browserPreparing)
                }.padding(12)
            }
        }
    }
    private var filterSummary: String {
        var labels: [String] = []
        if model.browserFilter.age != .all { labels.append(L10n.text(model.browserFilter.dateField.rawValue) + " · " + L10n.text(model.browserFilter.age.rawValue)) }
        labels += FileFormat.allCases.filter { model.browserFilter.formats.contains($0) }.map { L10n.text($0.rawValue) }
        return labels.joined(separator: " / ")
    }
    private func fileRow(_ file: ProjectFile) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.select(file.path)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(file.name).font(.system(size: 13, weight: model.selection == file.path ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                        if model.pins.contains(file.path) { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Palette.accent) }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: file.icon).font(.system(size: 17)).frame(width: 24, height: 24).background(Palette.surface, in: RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                        Text(file.category).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).lineLimit(1)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                    if file.path != file.name { Text((file.path as NSString).deletingLastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.horizontal, 8).padding(.vertical, 10)
            .background(model.selection == file.path ? Palette.accent.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                Button(model.pins.contains(file.path) ? L("移出常用文件") : L("加入常用文件")) { model.togglePin(file) }
                if file.convertible {
                    Button(L("转换为 Markdown")) {
                        model.convertFile(file)
                    }
                }
            }
    }

    private var reader: some View {
        VStack(spacing: 0) {
            if !model.isFullScreen {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text((model.current?.name ?? L("项目资料")) + (model.isDirty ? " •" : "")).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(model.current?.path ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        if let file = model.current {
                            if model.canEdit {
                                Button {
                                    if model.editing { model.showReading() } else { model.beginEditing() }
                                } label: {
                                    Image(systemName: model.editing ? "book" : "square.and.pencil")
                                        .symbolRenderingMode(.monochrome)
                                }
                                .foregroundStyle(model.editing ? Palette.accent : Color.primary)
                                .accessibilityLabel(model.editing ? L("切换到阅读模式") : L("切换到编辑模式"))
                                .accessibilityValue(model.editing ? L("编辑模式") : L("阅读模式"))
                                .disabled(model.saving || model.editorLoading || model.previewBusy)
                            }
                            Button {
                                model.togglePin(file)
                            } label: {
                                Image(systemName: model.pins.contains(file.path) ? "pin.fill" : "pin")
                            }.accessibilityLabel(model.pins.contains(file.path) ? L("移出常用文件") : L("加入常用文件"))
                            Button {
                                model.reveal()
                            } label: {
                                Image(systemName: "folder")
                            }.accessibilityLabel(L("在 Finder 中显示"))
                        }
                        if let root = model.root, let inspection = library.inspections[root.path] {
                            Menu {
                                ForEach(inspection.files.filter { model.browserIndex.byPath[$0] != nil }, id: \.self) { path in
                                    Button(path) { model.select(path) }
                                }
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }.accessibilityLabel(L("根目录关键文件")).disabled(model.busy || model.saving)
                        }
                        if model.canShowSplitPreview {
                            Button {
                                model.toggleSplitPreview()
                            } label: {
                                Image(systemName: "rectangle.split.2x1")
                            }
                            .foregroundStyle(model.previewVisible ? Palette.accent : Color.primary)
                            .accessibilityLabel(model.previewVisible ? L("收起分栏预览") : L("展开分栏预览"))
                            .accessibilityValue(model.previewVisible ? L("分栏") : L("单栏"))
                        }
                        Button {
                            model.toggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }.accessibilityLabel(L("主视图全屏"))
                        if model.canEdit {
                            Button {
                                Task { await model.saveDocument() }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }.accessibilityLabel(L("保存文件")).disabled(!model.isDirty || model.saving)
                        }
                        if model.saving || model.editorLoading { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(WorkspaceIconStyle()).padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 20)
                Divider()
            }
            if let file = model.current {
                if file.isEnvironment {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield"); Text(L("已脱敏")); Spacer()
                    }.font(.system(size: 12)).foregroundStyle(Palette.accent).padding(.horizontal, 24).padding(.vertical, 12).background(Palette.accent.opacity(0.05))
                } else if model.redactions > 0 && !model.editing {
                    HStack {
                        Image(systemName: "lock.shield"); Text(L("已隐藏 \(model.redactions) 处疑似敏感值")); Spacer()
                    }.font(.system(size: 12)).foregroundStyle(Palette.accent).padding(14)
                }
                HSplitView {
                    fileContent(file, main: true)
                        .frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
                    if model.canShowSplitPreview && model.previewVisible && !model.isFullScreen {
                        fileContent(file, main: false)
                            .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(L("Markdown 分栏预览"))
                    }
                }
            } else {
                VStack(spacing: 22) {
                    EmptyReader(title: "", icon: "square.stack.3d.up")
                    Button(L("打开项目…")) { model.chooseProject() }.controlSize(.large).padding(.bottom, 70)
                }
            }
        }.background(Palette.paper)
    }
    private func conversionPlaceholder(_ file: ProjectFile) -> some View {
        EmptyReader(title: file.convertible ? file.name : L("不支持预览"), icon: file.icon)
    }

    @ViewBuilder private func fileContent(_ file: ProjectFile, main: Bool) -> some View {
        if main && model.editing && model.document?.path == file.path {
            SourceEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }), editable: !model.saving, accessibilityName: file.category + L(" 编辑器"))
                .id(file.path)
        } else if model.previewBusy && file.isText {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if file.isMarkdown {
            if !main, let document = model.document, document.path == file.path {
                LiveMarkdownPreview(source: document.text).id(file.path)
            } else {
                MarkdownView(text: model.preview).id(file.path)
            }
        } else if file.isText {
            SourceText(text: model.preview)
        } else if let root = model.root, let url = try? ProjectFiles.checkedURL(root: root, path: file.path) {
            if file.size > 50_000_000 {
                EmptyReader(title: L("文件超过 50 MB"))
            } else if file.ext == "pdf" {
                PDFReader(url: url).id(file.path)
            } else if ["png", "jpg", "jpeg", "heic", "tiff", "bmp"].contains(file.ext) {
                LocalImage(url: url).id(file.path)
            } else if main {
                conversionPlaceholder(file)
            } else {
                EmptyReader(title: L("不支持预览"), icon: file.icon)
            }
        } else {
            EmptyReader(title: L("文件不存在"))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.saving { ProgressView().controlSize(.mini); Text(L("正在保存…")) } else if model.busy { ProgressView().controlSize(.mini); Text(model.busyText) } else if model.isDirty { Text(L("未保存")) }
            Spacer()
            if model.scanLimited { Text(L("部分内容分批载入 · 展开文件夹继续读取")).foregroundStyle(.secondary) }
        }.font(.system(size: 12)).padding(.horizontal, 18).frame(height: 32)
    }
}

struct ConversionSheet: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) var dismiss
    @State private var source = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("转换结果")).font(.system(size: 21, weight: .semibold)); Text(model.conversion?.source ?? "").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(); Button(source ? L("阅读视图") : L("源码")) { source.toggle() }; Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            if let conversion = model.conversion {
                if source { SourceText(text: conversion.markdown) } else { MarkdownView(text: conversion.markdown) }
                Divider()
                HStack {
                    Spacer(); Button(L("另存为 Markdown")) { model.saveConversion() }.buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(20)
            }
        }.controlSize(.large).frame(width: WorkspaceDialog.width, height: WorkspaceDialog.height).background(Palette.paper)
    }
}
