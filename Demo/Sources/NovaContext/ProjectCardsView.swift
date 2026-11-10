import AppKit
import ContextCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ProjectLibraryModel: ObservableObject {
  @Published private(set) var cards: [ProjectCard] = []
  @Published var error: String?
  @Published private(set) var inspections: [String: ProjectInspection] = [:]
  @Published private(set) var inspecting: Set<String> = []
  @Published private(set) var changed: Set<String> = []
  private var inspectionTasks: [String: Task<ProjectInspection, Error>] = [:]
  private let repository: ProjectLibrary
  private let bookmarks: ProjectBookmarks
  init(url: URL? = nil) {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    bookmarks = url.map { ProjectBookmarks(file: $0.deletingLastPathComponent().appendingPathComponent("bookmarks.json")) } ?? ProjectAccessPolicy.bookmarks
    repository = ProjectLibrary(
      url: url ?? root.appendingPathComponent("NovaContextDemo/ProjectLibrary/cards.json"))
  }
  func load() async {
    do { cards = try await repository.records() } catch { self.error = error.localizedDescription }
  }
  func visit(_ root: URL) async {
    do { cards = try await repository.visit(root) } catch {
      self.error = error.localizedDescription
    }
  }
  @discardableResult func inspect(_ root: URL) async -> ProjectInspection? {
    let path = root.standardizedFileURL.resolvingSymlinksInPath().path
    if let task = inspectionTasks[path] { return try? await task.value }
    let needsBookmark = ProjectAccessPolicy.needsBookmark(root)
    let bookmarks = bookmarks
    let task = Task.detached(priority: .userInitiated) {
      let access = try await bookmarks.acquire(root, required: needsBookmark)
      defer { withExtendedLifetime(access) {} }
      return try ProjectInspector.inspect(access.url)
    }
    inspectionTasks[path] = task
    inspecting.insert(path)
    defer {
      inspecting.remove(path)
      inspectionTasks[path] = nil
    }
    do {
      let result = try await task.value
      if let previous = inspections[path], previous.fingerprint != result.fingerprint {
        changed.insert(path)
      } else {
        changed.remove(path)
      }
      inspections[path] = result
      return result
    } catch {
      inspections[path] = nil
      self.error = L("配置检查未完成：") + error.localizedDescription
      return nil
    }
  }
  func exportBrief(_ card: ProjectCard, credentials: [CredentialRecord]) {
    guard !inspecting.contains(card.path) else { return }
    let panel = NSSavePanel()
    panel.title = L("导出 AI 项目说明")
    panel.nameFieldStringValue = "project-brief.md"
    panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      guard let inspection = await inspect(card.url) else { return }
      do {
        try await Task.detached(priority: .userInitiated) {
          let text = try ProjectBrief.markdown(
            card: card, inspection: inspection, credentials: credentials)
          try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        }.value
      } catch { self.error = L("项目说明未导出，请选择新文件：") + error.localizedDescription }
    }
  }
  func save(_ card: ProjectCard) async -> Bool {
    do {
      cards = try await repository.save(card)
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func remove(_ card: ProjectCard) async {
    do {
      if ProjectAccessPolicy.needsBookmark(card.url) { try await bookmarks.forget(card.url) }
      cards = try await repository.remove(card.path)
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct ProjectCardsView: View {
    @Environment(\.locale) private var locale
  @ObservedObject var library: ProjectLibraryModel
  @ObservedObject var vault: CredentialVaultModel
  let open: (ProjectCard) -> Void
  let add: () -> Void
  let manageCredentials: (URL) -> Void
  let exportBrief: (ProjectCard) -> Void
  let manageAuthorizations: (URL) -> Void
  let removeProject: (ProjectCard) async -> Void
  @State private var query = ""
  @State private var editor: ProjectCard?
  @State private var removing: ProjectCard?
  private var visible: [ProjectCard] {
    library.cards.filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        || $0.path.localizedCaseInsensitiveContains(query)
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Text(L("项目空间")).font(.title2.weight(.semibold))
        Spacer()
        TextField(L("搜索项目"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
        Button(action: add) { Label(L("添加项目"), systemImage: "plus") }
      }.padding(24)
      Divider()
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 300, maximum: 440), spacing: 18)],
          alignment: .leading, spacing: 18
        ) {
          ForEach(visible) { card in
            cardView(card)
          }
        }.padding(24)
        if visible.isEmpty {
          VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
            Text(query.isEmpty ? L("暂无项目") : L("无匹配项目")).foregroundStyle(.secondary)
            if query.isEmpty { Button(L("添加项目"), action: add) }
          }.padding(50)
        }
      }
    }.background(Palette.paper)
      .sheet(item: $editor) { card in ProjectCardEditor(library: library, card: card) }
      .alert(
        L("从项目空间移除？"),
        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
      ) {
        Button(L("取消"), role: .cancel) { removing = nil }
        Button(L("移除"), role: .destructive) {
          if let card = removing { Task { await removeProject(card) } }
          removing = nil
        }
      } message: {
        Text(L("同时作废此项目全部临时授权。保留磁盘文件、项目设置和钥匙串凭证。"))
      }
  }
  private func cardView(_ card: ProjectCard) -> some View {
    let linked = vault.linked(to: card.url)
    let apis = linked.filter { $0.kind == .api }
    let servers = linked.filter { $0.kind == .server }
    return VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(systemName: "folder").font(.title2).foregroundStyle(Palette.accent)
        Text(card.name).font(.headline).lineLimit(1)
        Spacer(minLength: 0)
        Menu {
          Button(L("AI 临时授权…")) { manageAuthorizations(card.url) }
          Button(L("编辑环境配置")) { editor = card }
          Button(L("管理 ENV 与后端配置")) { manageCredentials(card.url) }
          Button(L("检查配置")) { Task { await library.inspect(card.url) } }
            .disabled(library.inspecting.contains(card.path))
          Button(L("导出 AI 项目说明…")) { exportBrief(card) }
            .disabled(library.inspecting.contains(card.path) || vault.busy)
          Button(L("导出环境说明…")) { vault.export(root: card.url, configuration: card) }
          Divider()
          Button(L("从项目空间移除"), role: .destructive) { removing = card }
        } label: {
          Image(systemName: "ellipsis").frame(width: 32, height: 32)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(
          card.name + L("项目操作"))
      }
      Text(card.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(
        .middle)
      Divider()
      configuration(
        L("手填环境"), icon: "slider.horizontal.3",
        value: L10n.environment(card.environment) + (card.runtime.isEmpty ? "" : " · " + card.runtime))
      configuration(
        "ENV", icon: "key",
        value: apis.isEmpty
          ? L("未关联")
          : apis.prefix(3).map {
            $0.variable + " · " + L10n.environment($0.environment)
              + ($0.lifecycle() == .normal ? "" : " · " + L10n.text($0.lifecycle().rawValue))
              + ($0.expiresAt.map { " · " + $0.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(L10n.locale)) } ?? "")
          }.joined(separator: "\n"),
        count: apis.count)
      configuration(
        L("后端"), icon: "server.rack",
        value: servers.isEmpty
          ? L("未关联")
          : servers.prefix(2).map {
            $0.name + " · " + L10n.environment($0.environment) + "\n" + $0.address + ":" + String($0.port)
          }.joined(separator: "\n"), count: servers.count)
      inspectionSummary(card)
      Spacer(minLength: 0)
      HStack {
        Text(card.opened, format: .dateTime.month().day().hour().minute()).font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Menu(L("配置")) {
          Button(L("编辑环境配置")) { editor = card }
          Menu(L("关联 ENV / 后端")) {
            ForEach(vault.records) { record in
              Toggle(
                record.name + " · " + L10n.environment(record.environment),
                isOn: Binding(
                  get: { linked.contains { $0.id == record.id } },
                  set: { value in Task { await vault.link(record, root: card.url, linked: value) } }
                ))
            }
            Divider()
            Button(L("管理凭证…")) { manageCredentials(card.url) }
          }.disabled(vault.busy)
        }
        Button(L("打开")) { open(card) }.buttonStyle(.borderedProminent)
      }
    }.padding(18).frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
      .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1) }
      .accessibilityElement(children: .contain).accessibilityLabel(card.name + L("项目卡片"))
  }
  @ViewBuilder private func inspectionSummary(_ card: ProjectCard) -> some View {
    if library.inspecting.contains(card.path) {
      HStack {
        ProgressView().controlSize(.small)
        Text(L("检查配置中…")).font(.caption)
      }
    } else if let result = library.inspections[card.path] {
      VStack(alignment: .leading, spacing: 5) {
        Label(
          result.runtimeSummary.isEmpty ? L("未识别运行环境") : result.runtimeSummary,
          systemImage: "doc.text.magnifyingglass"
        )
        .font(.caption).lineLimit(2)
        Text(result.runtimes.map { $0.source }.joined(separator: " · "))
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        Text(
          L("根目录 · ") + L("\(result.environmentVariables.values.reduce(0) { $0 + $1.count }) 个 ENV 变量名")
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Text(result.checked, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(
            .secondary)
          if library.changed.contains(card.path) {
            Text(L("配置来源已变化")).font(.caption2).foregroundStyle(.orange)
          }
          if !result.warnings.isEmpty {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
              .help(result.warnings.joined(separator: "\n")).accessibilityLabel(
                result.warnings.joined(separator: "；"))
          }
          Spacer()
          Button(L("重新检查")) { Task { await library.inspect(card.url) } }.font(.caption)
        }
      }
    } else {
      Button(L("检查根目录配置")) { Task { await library.inspect(card.url) } }.font(.caption)
    }
  }

  private func configuration(_ title: String, icon: String, value: String, count: Int = 0)
    -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
        if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
      }
      Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4).textSelection(
        .enabled)
    }
  }
}

private struct ProjectCardEditor: View {
    @Environment(\.locale) private var locale
  @ObservedObject var library: ProjectLibraryModel
  @State var card: ProjectCard
  @Environment(\.dismiss) private var dismiss
  @State private var saving = false
  var body: some View {
    VStack(spacing: 18) {
      Text(L("项目配置")).font(.headline)
      Form {
        TextField(L("项目名称"), text: $card.name)
        Picker(L("环境"), selection: $card.environment) {
          ForEach(["开发", "测试", "生产"], id: \.self) { Text(L10n.environment($0)).tag($0) }
        }
        TextField(L("运行环境"), text: $card.runtime, prompt: Text("Node.js 22 / Python 3.12"))
      }
      HStack {
        Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(L("保存")) {
          saving = true
          Task {
            if await library.save(card) { dismiss() }
            saving = false
          }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 420).disabled(saving).interactiveDismissDisabled()
  }
}
