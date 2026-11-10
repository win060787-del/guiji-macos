import AppKit
import ContextCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class LocalServicesModel: ObservableObject {
  @Published var presented = false
  @Published var project: String = ""
  @Published private(set) var grants: [TemporaryGrant] = []
  @Published private(set) var running = false
  @Published private(set) var busy = false
  @Published var error: String?
  @Published var issued: IssuedGrant?
  private let vault: CredentialVault
  private let store: TemporaryGrantStore
  private let broker: LocalGrantBroker
  private let socket: LocalSocketService
  var socketPath: String { socket.url.path }
  init(vault: CredentialVault, directory: URL? = nil) {
    self.vault = vault
    let data = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NovaContextDemo")
    let store = TemporaryGrantStore(url: data.appendingPathComponent("Authorizations/grants.json"))
    self.store = store
    broker = LocalGrantBroker(grants: store, vault: vault)
    socket = LocalSocketService(
      url: ServiceEndpoint.socket(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), fallback: data,
        sandboxed: directory == nil && Bundle.main.object(forInfoDictionaryKey: "NovaContextAppStoreBuild") as? Bool == true), broker: broker)
  }
  func load() async {
    do { grants = try await store.records() } catch { self.error = L("授权记录无法读取，相关请求将被拒绝") }
  }
  func setRunning(_ enabled: Bool) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    if enabled {
      do {
        _ = try await store.records()
        let socket = socket
        try await Task.detached { try socket.start() }.value
        await broker.setEnabled(true)
        running = true
      } catch {
        socket.stop()
        self.error = L("服务未启动：") + error.localizedDescription
      }
    } else {
      await broker.setEnabled(false)
      let socket = socket
      await Task.detached { socket.stop() }.value
      running = false
    }
  }
  func shutdown() {
    socket.stop()
    running = false
  }
  func create(credentialID: UUID, days: Int, name: String, replacing: UUID? = nil) async {
    guard !busy, !project.isEmpty else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let scope = project
      let credential = try await vault.apiCredential(credentialID, project: scope)
      issued = try await store.issue(
        name: name, project: scope, credential: credential, days: days, replacing: replacing)
      grants = try await store.records()
    } catch { self.error = error.localizedDescription }
  }
  func revoke(_ record: TemporaryGrant) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await store.revoke(record.id)
      grants = try await store.records()
    } catch { self.error = error.localizedDescription }
  }
  @discardableResult func revokeProject(_ scope: String? = nil) async -> Bool {
    let path = scope ?? project
    guard !busy, !path.isEmpty else { return false }
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await store.revokeProject(path)
      grants = try await store.records()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func remove(_ record: TemporaryGrant) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await store.remove(record.id)
      grants = try await store.records()
    } catch { self.error = error.localizedDescription }
  }
  func copyNativeCommand() {
    guard let executable = Bundle.main.executableURL else { return }
    let panel = NSOpenPanel(); panel.title = L("选择已导出的临时授权文件")
    panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let grant = panel.url else { return }
    func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let command = quoted(executable.path) + " --agent < " + quoted(grant.path)
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
  }
  func exportClient() {
    guard let source = Bundle.main.resourceURL?.appendingPathComponent("nova-agent.py") else {
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "nova-agent.py"
    guard panel.runModal() == .OK, let target = panel.url else { return }
    Task {
      do {
        try await Task.detached { try PrivateFile.writeNew(Data(contentsOf: source), to: target) }
          .value
      } catch { self.error = L("客户端未导出，请使用打包后的应用并选择新文件名") }
    }
  }
  func export(_ issued: IssuedGrant) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "nova-agent-grant.json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    struct Export: Encodable {
      let version = 1
      let socket: String
      let project: String
      let operation = "github.identity"
      let token: String
      let expiresAt: Date
    }
    let object = Export(
      socket: socketPath, project: issued.record.project, token: issued.token,
      expiresAt: issued.record.expiresAt)
    Task {
      do {
        try await Task.detached {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          encoder.dateEncodingStrategy = .iso8601
          try PrivateFile.writeNew(encoder.encode(object), to: url)
        }.value
      } catch { self.error = error.localizedDescription }
    }
  }
}

struct LocalServicesView: View {
    @Environment(\.locale) private var locale
  @ObservedObject var services: LocalServicesModel
  @ObservedObject var vault: CredentialVaultModel
  let projects: [ProjectCard]
  @Environment(\.dismiss) private var dismiss
  @State private var credentialID: UUID?
  @State private var days = 7
  @State private var name = ""
  @State private var revokingAll = false
  @State private var showVault = false
  private var eligible: [CredentialRecord] {
    vault.records.filter {
      $0.kind == .api && $0.secretID != nil && GitHubIdentityAdapter.accepts($0.address)
        && $0.projects.contains(where: { $0.path == services.project })
        && ($0.expiresAt.map { $0 > Date() } ?? true)
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(L("本机服务"), systemImage: "server.rack").font(.headline)
        Spacer()
        Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(20)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Circle().fill(services.running ? .green : .secondary).frame(width: 8, height: 8)
            Text(services.running ? L("授权服务运行中") : L("授权服务已停止"))
            if services.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(services.running ? L("停止") : L("启动")) {
              Task { await services.setRunning(!services.running) }
            }
            .disabled(services.busy)
          }
          if services.running {
            Text(services.socketPath).font(.caption.monospaced()).foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          HStack {
            Label(vault.reminderStatus, systemImage: "bell")
            if vault.pendingReminders > 0 {
              Text(L("\(vault.pendingReminders) 条")).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("同步提醒")) { vault.syncReminders(requestPermission: true) }
          }
          if vault.deferredReminders > 0 {
            Text(L("另有 \(vault.deferredReminders) 条待补排")).font(.caption).foregroundStyle(.secondary)
          }
          Menu(L("Agent 客户端")) {
            Button(L("复制原生调用命令…")) { services.copyNativeCommand() }
            Button(L("导出 Python 示例…")) { services.exportClient() }
          }
          Divider()
          Picker(L("项目"), selection: $services.project) {
            Text(L("选择项目")).tag("")
            ForEach(projects) { Text($0.name).tag($0.path) }
            ForEach(
              Array(Set(services.grants.map(\.project))).filter { path in
                !projects.contains(where: { $0.path == path })
              }.sorted(), id: \.self
            ) { path in
              Text(L("已移除 · ") + URL(fileURLWithPath: path).lastPathComponent).tag(path)
            }
          }.onChange(of: services.project) { _, _ in credentialID = nil }
          HStack {
            Text(L("GitHub · 读取当前账户")).font(.headline)
            Spacer()
            Button(L("管理凭证")) { showVault = true }
          }
          Picker(L("凭证"), selection: $credentialID) {
            Text(L("选择已关联的 GitHub 凭证")).tag(UUID?.none)
            ForEach(eligible) { Text($0.name + " · " + $0.environment).tag(Optional($0.id)) }
          }
          TextField(L("授权名称"), text: $name, prompt: Text(L("GitHub 只读授权")))
          HStack {
            Stepper(L("有效 \(days) 天"), value: $days, in: 1...365)
            Spacer()
            Button(L("创建授权")) {
              if let credentialID {
                Task { await services.create(credentialID: credentialID, days: days, name: name) }
              }
            }.disabled(
              credentialID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || services.busy)
          }
          Divider()
          TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text(L("项目授权")).font(.headline)
                Spacer()
                Button(L("刷新")) { Task { await services.load() } }
                Button(L("全部作废"), role: .destructive) { revokingAll = true }
                  .disabled(
                    services.project.isEmpty || services.busy
                      || services.grants.filter {
                        $0.project == services.project && $0.revokedAt == nil
                      }.isEmpty)
              }
              ForEach(services.grants.filter { $0.project == services.project }) { grant in
                grantRow(grant, now: context.date)
              }
              if services.grants.filter({ $0.project == services.project }).isEmpty {
                Text(L("暂无授权")).foregroundStyle(.secondary).padding(.vertical, 12)
              }
            }
          }
          if let error = services.error { Text(error).foregroundStyle(.red) }
        }.padding(24)
      }
    }.frame(width: 740, height: 620)
      .task {
        await services.load()
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(5)) } catch { break }
          if !services.busy { await services.load() }
        }
      }
      .sheet(isPresented: $showVault) {
        CredentialVaultView(
          vault: vault,
          project: services.project.isEmpty ? nil : URL(fileURLWithPath: services.project)
        )
        .alert(
          L("环境与凭证"),
          isPresented: Binding(get: { vault.error != nil }, set: { if !$0 { vault.error = nil } })
        ) {
          Button(L("好")) { vault.error = nil }
        } message: {
          Text(vault.error ?? "")
        }
      }
      .sheet(item: $services.issued, onDismiss: { services.issued = nil }) { issued in
        IssuedGrantView(issued: issued, services: services, vault: vault)
      }
      .alert(L("作废此项目的全部授权？"), isPresented: $revokingAll) {
        Button(L("取消"), role: .cancel) {}
        Button(L("全部作废"), role: .destructive) { Task { await services.revokeProject() } }
      } message: {
        Text(L("后续请求将被拒绝。已完成或已受理的请求无法收回。"))
      }
  }
  private func status(_ grant: TemporaryGrant, now: Date) -> String {
    if grant.revokedAt != nil || grant.expiresAt <= now { return grant.status(at: now) }
    guard let credential = vault.records.first(where: { $0.id == grant.credentialID }),
      credential.projects.contains(where: { $0.path == grant.project }),
      credential.expiresAt.map({ $0 > now }) ?? true
    else { return L("凭证不可用") }
    return CredentialRevision.of(credential) == grant.credentialRevision ? L("有效") : L("凭证已变更")
  }
  private func grantRow(_ grant: TemporaryGrant, now: Date) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(grant.name, systemImage: "key.horizontal")
        Spacer()
        Text(status(grant, now: now)).foregroundStyle(
          status(grant, now: now) == L("有效") ? .green : .secondary)
      }
      HStack {
        Text(grant.expiresAt, format: .dateTime.year().month().day().hour().minute()).font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if grant.revokedAt == nil {
          Button(L("作废"), role: .destructive) { Task { await services.revoke(grant) } }
        }
        Button(L("重新生成")) {
          Task {
            await services.create(
              credentialID: grant.credentialID, days: days, name: grant.name, replacing: grant.id)
          }
        }
        if grant.revokedAt != nil || grant.expiresAt <= now {
          Button {
            Task { await services.remove(grant) }
          } label: {
            Image(systemName: "trash")
          }.accessibilityLabel(L("删除失效授权记录"))
        }
      }.disabled(services.busy)
      if let outcome = grant.lastOutcome {
        Text(L("最近调用 · ") + L10n.text(outcome)).font(.caption).foregroundStyle(.secondary)
      }
    }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct IssuedGrantView: View {
    @Environment(\.locale) private var locale
  let issued: IssuedGrant
  @ObservedObject var services: LocalServicesModel
  @ObservedObject var vault: CredentialVaultModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label(L("临时授权"), systemImage: "key.horizontal").font(.headline)
      Text(issued.token).font(.system(.body, design: .monospaced)).textSelection(.enabled)
      Text(L("仅显示一次。此授权可代用指定凭证，请勿公开或提交到 Git。")).font(.caption).foregroundStyle(.secondary)
      LabeledContent(L("到期"), value: issued.record.expiresAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
      HStack {
        Button(L("复制授权")) { vault.copySecret(issued.token) }
        Button(L("导出 Agent 授权…")) { services.export(issued) }
        Spacer()
        Button(L("完成")) {
          services.issued = nil
          dismiss()
        }.keyboardShortcut(.defaultAction)
      }
      if let error = services.error { Text(error).foregroundStyle(.red) }
    }.padding(24).frame(width: 660)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
      ) { _ in
        services.issued = nil
      }
  }
}
