import SwiftUI
import AppKit
import ContextCore

@MainActor final class CredentialVaultModel: ObservableObject {
    @Published var records: [CredentialRecord] = []
    @Published var busy = false
    @Published var error: String?
    @Published var presented = false
    @Published var selection: UUID?
    @Published var editorDirty = false
    func confirmDiscardEditor() -> Bool {
        guard editorDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("放弃未保存的凭证更改？")
        alert.addButton(withTitle: L("继续编辑"))
        alert.addButton(withTitle: L("放弃更改"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    @Published private var reminderStatusKey = "提醒未开启"
    var reminderStatus: String { L10n.text(reminderStatusKey) }
    @Published var pendingReminders = 0
    @Published var deferredReminders = 0
    private let notifications = CredentialNotifications()
    private var notificationTask: Task<Void, Never>?
    func syncReminders(requestPermission: Bool = false) {
        let records = records, previous = notificationTask
        notificationTask = Task {
            await previous?.value
            let result = await notifications.reconcile(records, requestPermission: requestPermission)
            reminderStatusKey = result.key; pendingReminders = result.pending; deferredReminders = result.deferred
        }
    }
    func flushReminders() async { await notificationTask?.value }
    let repository: CredentialVault
    init(repository: CredentialVault? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.repository = repository ?? CredentialVault(url: root.appendingPathComponent("NovaContextDemo/Credentials/vault.json"))
    }
    func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { records = try await repository.records(); syncReminders() } catch { self.error = error.localizedDescription }
    }
    func save(_ record: CredentialRecord, secret: String) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        do {
            records = try await repository.save(record, secret: secret.isEmpty ? nil : secret)
            syncReminders(requestPermission: record.remindersEnabled == true)
            selection = record.id; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func link(_ record: CredentialRecord, root: URL, linked: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { records = try await repository.link(record.id, project: CredentialProject(url: root), linked: linked); syncReminders() } catch { self.error = error.localizedDescription }
    }
    func delete(_ record: CredentialRecord) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { records = try await repository.delete(record.id); selection = nil; syncReminders() } catch { self.error = error.localizedDescription }
    }
    func reveal(_ record: CredentialRecord) async -> String? {
        guard !busy else { return nil }
        busy = true; defer { busy = false }
        do { return try await repository.reveal(record.id) } catch { self.error = error.localizedDescription; return nil }
    }
    func linked(to root: URL) -> [CredentialRecord] {
        records.filter { $0.projects.contains { $0.path == root.standardizedFileURL.path } }
    }
    func export(root: URL, configuration: ProjectCard? = nil) {
        let snapshot = records
        let panel = NSSavePanel(); panel.nameFieldStringValue = "environment.context.json"
        panel.allowedContentTypes = [.json]; panel.title = L("导出环境说明（不含密钥）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached {
                    let data = try CredentialVault.environmentDescription(records: snapshot, project: CredentialProject(url: root), configuration: configuration)
                    try data.write(to: url, options: .atomic)
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
    func copySecret(_ value: String) {
        let board = NSPasteboard.general; board.clearContents()
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.writeObjects([item]); let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            if board.changeCount == count { board.clearContents() }
        }
    }
}

struct CredentialVaultView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vault: CredentialVaultModel
    let project: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind: CredentialKind?
    @State private var editor: CredentialRecord?
    @State private var deleting: CredentialRecord?
    private var visible: [CredentialRecord] {
        vault.records.filter { record in
            (kind == nil || record.kind == kind) && (query.isEmpty || record.name.localizedCaseInsensitiveContains(query) || record.address.localizedCaseInsensitiveContains(query))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("环境与凭证"), systemImage: "key").font(.headline)
                Spacer()
                Label(L("本机钥匙串"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(vault.busy)
            }.padding(18)
            Divider()
            HSplitView {
                VStack(spacing: 12) {
                    TextField(L("搜索凭证"), text: $query).textFieldStyle(.roundedBorder).accessibilityLabel(L("搜索凭证"))
                    Picker(L("类型"), selection: $kind) {
                        Text(L("全部")).tag(CredentialKind?.none)
                        ForEach(CredentialKind.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag(Optional($0)) }
                    }.labelsHidden()
                    List(visible, selection: $vault.selection) { record in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(record.name, systemImage: record.kind == .api ? "key" : "server.rack").font(.system(size: 13, weight: .medium))
                            Text(L10n.environment(record.environment) + " · " + L10n.text(record.kind.rawValue)).font(.caption).opacity(0.75)
                            if !record.projects.isEmpty { Text(record.projects.map(\.name).joined(separator: " · ")).font(.caption).opacity(0.75).lineLimit(1) }
                        }.foregroundStyle(vault.selection == record.id ? Color.white : Color.primary)
                            .padding(.vertical, 7).tag(record.id)
                            .listRowBackground(vault.selection == record.id ? Palette.accent : Color.clear)
                    }.listStyle(.sidebar)
                    Menu {
                        Button(L("API 凭证")) {
                            var value = CredentialRecord(); value.kind = .api; editor = value
                        }
                        Button(L("服务器")) {
                            var value = CredentialRecord(); value.kind = .server; editor = value
                        }
                    } label: {
                        Label(L("新增凭证"), systemImage: "plus")
                    }.disabled(vault.busy)
                }.padding(14).frame(minWidth: 250, idealWidth: 270, maxWidth: 330).background(FrostedPanel())
                Group {
                    if let record = vault.records.first(where: { $0.id == vault.selection }) {
                        CredentialDetail(
                            vault: vault, record: record, project: project,
                            edit: { editor = record }, delete: { deleting = record }
                        ).id(record)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "key").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text(L("环境与凭证")).font(.title3)
                            Button(L("新增 API 凭证")) { editor = CredentialRecord() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper)
            }
        }.frame(width: WorkspaceDialog.width, height: WorkspaceDialog.height)
            .sheet(item: $editor) { record in CredentialEditor(vault: vault, initial: record) }
            .alert(L("删除凭证？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L("取消"), role: .cancel) { deleting = nil }
                Button(L("删除"), role: .destructive) {
                    if let deleting { Task { await vault.delete(deleting) } }; deleting = nil
                }
            } message: {
                Text(L("将从本机钥匙串删除此凭证，并解除全部项目关联。此操作无法撤销。"))
            }
    }
}

private struct CredentialDetail: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vault: CredentialVaultModel
    let record: CredentialRecord
    let project: URL?
    let edit: () -> Void
    let delete: () -> Void
    @State private var revealed: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label(record.name, systemImage: record.kind == .api ? "key" : "server.rack").font(.title2)
                    Spacer(); Button(L("编辑"), action: edit).disabled(vault.busy)
                }
                Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 16) {
                    row(L("类型"), L10n.text(record.kind.rawValue))
                    row(L("环境"), L10n.environment(record.environment))
                    row(L("状态"), L10n.text(record.lifecycle().rawValue))
                    if let added = record.addedAt { row(L("添加日期"), added.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) }
                    if let expires = record.expiresAt { row(L("到期日期"), expires.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) }
                    if let rotate = record.rotateAt { row(L("轮换日期"), rotate.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) }
                    if record.kind == .api {
                        if !record.provider.isEmpty { row(L("服务商"), record.provider) }
                        row(L("服务地址"), record.address); row(L("变量名"), record.variable)
                    } else {
                        row(L("地址"), record.address); row(L("端口"), String(record.port)); row(L("用户名"), record.username)
                        row(L("认证方式"), L10n.text(record.authentication.rawValue))
                        if record.authentication == .sshKey { row(L("密钥文件"), record.keyPath) }
                        if !record.deployPath.isEmpty { row(L("部署目录"), record.deployPath) }
                    }
                }.textSelection(.enabled)
                if record.secretID != nil {
                    Divider()
                    HStack {
                        Text(record.kind == .api ? "Token" : L("密码")).foregroundStyle(.secondary)
                        Text(revealed ?? "••••••••••••").font(.system(.body, design: .monospaced)).lineLimit(2)
                        Spacer()
                        Button(revealed == nil ? L("查看") : L("隐藏")) {
                            if revealed != nil { revealed = nil } else { Task { revealed = await vault.reveal(record) } }
                        }.disabled(vault.busy)
                        Button(L("复制")) { Task { if let value = await vault.reveal(record) { vault.copySecret(value) } } }.disabled(vault.busy)
                    }
                }
                Divider()
                Text(L("关联项目")).font(.headline)
                ForEach(record.projects, id: \.path) { project in
                    HStack {
                        Label(project.name, systemImage: "folder").help(project.path)
                        Spacer()
                        Button(L("解除关联")) { Task { await vault.link(record, root: URL(fileURLWithPath: project.path), linked: false) } }.disabled(vault.busy)
                    }
                }
                if let project, !record.projects.contains(where: { $0.path == project.standardizedFileURL.path }) {
                    Button(L("关联到“\(project.lastPathComponent)”")) { Task { await vault.link(record, root: project, linked: true) } }.disabled(vault.busy)
                }
                Spacer(minLength: 20)
                Button(L("删除凭证…"), role: .destructive, action: delete).disabled(vault.busy)
            }.padding(28)
        }.onDisappear { revealed = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in revealed = nil }
            .onChange(of: revealed) { _, value in
                guard value != nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(30)); revealed = nil
                }
            }
    }
    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary); Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CredentialEditor: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vault: CredentialVaultModel
    @Environment(\.dismiss) private var dismiss
    @State private var record: CredentialRecord
    @State private var secret = ""
    @State private var changed = false
    @State private var confirmingDiscard = false
    @State private var validation: String?
    init(vault: CredentialVaultModel, initial: CredentialRecord) {
        self.vault = vault; _record = State(initialValue: initial)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text(record.kind.rawValue)).font(.headline); Spacer(); Label(L("本机钥匙串"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Form {
                TextField(L("名称"), text: $record.name)
                Picker(L("环境"), selection: $record.environment) {
                    Text(L("开发")).tag("开发"); Text(L("测试")).tag("测试"); Text(L("生产")).tag("生产")
                }
                if record.kind == .api {
                    HStack {
                        TextField(L("服务商"), text: $record.provider)
                        Menu(L("服务预设")) {
                            Button("GitHub") {
                                record.provider = "GitHub"; record.address = "https://api.github.com"; record.variable = "GITHUB_TOKEN"
                            }
                        }
                    }
                    TextField(L("服务地址"), text: $record.address, prompt: Text("https://api.example.com"))
                    TextField(L("变量名"), text: $record.variable, prompt: Text("API_TOKEN"))
                } else {
                    TextField(L("主机 / IP"), text: $record.address)
                    TextField(L("端口"), value: $record.port, format: .number.grouping(.never))
                    TextField(L("用户名"), text: $record.username)
                    Picker(L("认证方式"), selection: $record.authentication) {
                        ForEach(ServerAuthentication.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                    }
                    if record.authentication == .sshKey {
                        HStack {
                            TextField(L("密钥文件"), text: $record.keyPath)
                            Button(L("选择…")) {
                                let panel = NSOpenPanel(); panel.title = L("选择 SSH 密钥文件")
                                panel.showsHiddenFiles = true; panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url { record.keyPath = url.path }
                            }
                        }
                    }
                    TextField(L("部署目录"), text: $record.deployPath)
                }
                Section(L("日期与提醒")) {
                    Toggle(L("设置到期日期"), isOn: Binding(get: { record.expiresAt != nil }, set: { record.expiresAt = $0 ? Date().addingTimeInterval(30 * 86400) : nil }))
                    if record.expiresAt != nil {
                        DatePicker(L("到期"), selection: Binding(get: { record.expiresAt ?? Date() }, set: { record.expiresAt = $0 }))
                    }
                    Toggle(L("设置轮换日期"), isOn: Binding(get: { record.rotateAt != nil }, set: { record.rotateAt = $0 ? Date().addingTimeInterval(90 * 86400) : nil }))
                    if record.rotateAt != nil {
                        DatePicker(L("轮换"), selection: Binding(get: { record.rotateAt ?? Date() }, set: { record.rotateAt = $0 }))
                    }
                    Toggle(L("本机通知"), isOn: Binding(get: { record.remindersEnabled == true }, set: { record.remindersEnabled = $0 }))
                    if record.remindersEnabled == true {
                        HStack {
                            ForEach([7, 3, 1, 0], id: \.self) { day in
                                Toggle(day == 0 ? L("当天") : L("提前 \(day) 天"), isOn: Binding(
                                    get: { (record.reminderDays ?? [7, 1, 0]).contains(day) },
                                    set: { enabled in
                                        var days = Set(record.reminderDays ?? [7, 1, 0])
                                        if enabled { days.insert(day) } else { days.remove(day) }
                                        record.reminderDays = days.sorted(by: >)
                                    }))
                            }
                        }
                    }
                }
                if record.needsSecret {
                    SecureField(
                        record.kind == .api ? "Token" : L("密码"), text: $secret,
                        prompt: Text(record.secretID == nil ? "" : L("留空保留现有值")))
                }
                if let validation { Text(validation).foregroundStyle(.red) }
                if let error = vault.error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).disabled(vault.busy)
            HStack {
                if vault.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("取消")) { if changed { confirmingDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction).disabled(vault.busy)
                Button(L("保存")) {
                    do {
                        try record.validate(); validation = nil; vault.error = nil
                        Task { if await vault.save(record, secret: secret) { secret = ""; dismiss() } }
                    } catch { validation = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(vault.busy)
            }.padding(20)
        }.frame(width: 640, height: 650)
            .interactiveDismissDisabled()
            .onChange(of: record) { _, _ in
                changed = true; vault.editorDirty = true
            }
            .onChange(of: secret) { _, _ in
                changed = true; vault.editorDirty = true
            }
            .onAppear {
                vault.error = nil; vault.editorDirty = false
            }
            .onDisappear {
                secret = ""; vault.editorDirty = false
            }
            .alert(L("放弃未保存的更改？"), isPresented: $confirmingDiscard) {
                Button(L("继续编辑"), role: .cancel) {}
                Button(L("放弃更改"), role: .destructive) {
                    secret = ""; dismiss()
                }
            }
    }
}

struct ProjectCredentialTags: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vault: CredentialVaultModel
    let root: URL
    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vault.linked(to: root)) { record in
                        Menu {
                            Text(L10n.environment(record.environment) + " · " + L10n.text(record.kind.rawValue))
                            Button(L("查看配置")) {
                                vault.selection = record.id; vault.presented = true
                            }
                            if record.kind == .api {
                                Button(L("复制变量名")) {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.variable, forType: .string)
                                }
                            }
                            Button(L("解除项目关联")) { Task { await vault.link(record, root: root, linked: false) } }
                        } label: {
                            Label(record.name, systemImage: record.kind == .api ? "key" : "server.rack")
                                .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
            Menu {
                ForEach(vault.records) { record in
                    Toggle(
                        record.name + " · " + L10n.environment(record.environment),
                        isOn: Binding(
                            get: { vault.linked(to: root).contains { $0.id == record.id } },
                            set: { linked in Task { await vault.link(record, root: root, linked: linked) } }))
                }
                Divider()
                Button(L("管理凭证…")) { vault.presented = true }
                Button(L("导出环境说明…")) { vault.export(root: root) }.disabled(vault.linked(to: root).isEmpty)
            } label: {
                Image(systemName: "plus").frame(width: 30, height: 30).accessibilityLabel(L("关联项目凭证"))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("关联项目凭证"))
        }.padding(.horizontal, 12).padding(.bottom, 8).disabled(vault.busy)
    }
}
