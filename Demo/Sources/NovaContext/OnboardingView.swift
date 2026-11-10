import SwiftUI
import ContextCore

enum OnboardingDestination { case workspace, credentials, services }
enum AppHelp {
    static let onboarding = Notification.Name("NovaContext.ShowOnboarding")
    static let manual = Notification.Name("NovaContext.ShowManual")
    static let privacy = Notification.Name("NovaContext.ShowPrivacy")
    static let terms = Notification.Name("NovaContext.ShowTerms")
}
struct OnboardingView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: WorkspaceModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var flow = OnboardingFlow()
    let finish: (OnboardingDestination) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image("BrandLogo", bundle: .module).resizable().scaledToFit().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(L("归记")).font(.headline)
                Spacer()
                Button(L("稍后设置")) { flow.skip(); finish(.workspace) }
            }.padding(24)
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Capsule().fill(step.rawValue <= flow.step.rawValue ? Palette.accent : Color.secondary.opacity(0.15)).frame(height: 4)
                }
            }.padding(.horizontal, 24).accessibilityLabel(L("第 \(flow.step.rawValue + 1) 步，共 \(OnboardingStep.allCases.count) 步"))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(flow.step.title).font(.system(size: 28, weight: .semibold))
                    switch flow.step {
                    case .language:
                        LanguagePicker()
                    case .project:
                        action(L("打开项目"), symbol: "folder.badge.plus", detail: L("选择本机文件夹")) { model.chooseProject() }
                        action(L("体验示例"), symbol: "doc.text", detail: L("使用内置示例项目")) { model.openDemo() }
                        if let root = model.root {
                            Label(root.lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                        }
                    case .appearance:
                        ForEach([("system", L("跟随系统"), "circle.lefthalf.filled"), ("light", L("浅色"), "sun.max"), ("dark", L("深色"), "moon")], id: \.0) { value in
                            Button { appearance = value.0 } label: {
                                HStack {
                                    Image(systemName: value.2).font(.title2).frame(width: 36)
                                    Text(value.1).font(.headline)
                                    Spacer()
                                    Image(systemName: appearance == value.0 ? "checkmark.circle.fill" : "circle")
                                }.padding(18).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(appearance == value.0 ? Palette.accent.opacity(0.12) : Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityAddTraits(appearance == value.0 ? .isSelected : [])
                        }
                    case .access:
                        action(L("环境与凭证"), symbol: "key", detail: L("API、服务器与到期提醒")) { flow.skip(); finish(.credentials) }
                        action(L("本机服务"), symbol: "server.rack", detail: L("创建可到期、可作废的 AI 授权")) { flow.skip(); finish(.services) }
                        Label(L("密钥保存在本机钥匙串。服务默认关闭，通知按需授权。"), systemImage: "lock.shield")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.busy { ProgressView(model.busyText).controlSize(.small) }
                    if let error = model.message { Text(error).foregroundStyle(.red) }
                }.padding(24)
            }
            Divider()
            HStack {
                Button(L("上一步")) { flow.back() }.disabled(flow.step == .language || model.busy)
                Spacer()
                Button(flow.step == .access ? L("进入项目") : L("继续")) {
                    if flow.next(hasProject: model.root != nil), flow.completed { finish(.workspace) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || (flow.step == .project && model.root == nil))
            }.padding(24)
        }.frame(width: min(740, WorkspaceDialog.width), height: min(610, WorkspaceDialog.height))
            .background(Palette.paper).interactiveDismissDisabled()
    }
    private func action(_ title: String, symbol: String, detail: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 25)).frame(width: 42, height: 42).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(18).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
enum BundledGuide: String, Identifiable { case manual = "使用手册", privacy = "隐私政策", terms = "使用条款"
    var id: String { rawValue }
}
struct UserGuideView: View {
    @Environment(\.locale) private var locale
    var document: BundledGuide = .manual
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text(document.rawValue), systemImage: "book").font(.headline)
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if let error { Text(error).foregroundStyle(.red).padding(24) }
            else if text.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { MarkdownView(text: text) }
        }.frame(width: WorkspaceDialog.width, height: WorkspaceDialog.height)
            .task(id: document.id + ":" + locale.identifier) {
                text = ""; error = nil
                guard let root = Bundle.module.url(forResource: "Resources", withExtension: nil) else { error = L("文档未打包"); return }
                let directory = L10n.language == .simplifiedChinese ? "Documentation" : "Documentation/" + L10n.language.rawValue
                let file = root.appendingPathComponent(directory + "/" + document.rawValue + ".md")
                do {
                    let loaded = try await Task.detached { try String(contentsOf: file, encoding: .utf8) }.value
                    guard !Task.isCancelled else { return }
                    text = loaded
                }
                catch { if !Task.isCancelled { self.error = L("文档无法读取") } }
            }
    }
}


struct LanguagePicker: View {
    @Environment(\.locale) private var locale
    @AppStorage("appLanguage") private var selection = "system"
    var body: some View {
        Picker(L("语言"), selection: $selection) {
            Text(L("跟随系统")).tag("system")
            ForEach(AppLanguage.allCases) { language in
                Text(language.nativeName).tag(language.rawValue)
            }
        }.pickerStyle(.radioGroup)
            .labelsHidden()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(L("语言"))
    }
}
struct LanguageSettingsView: View {
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L("语言"), systemImage: "globe").font(.title2)
            LanguagePicker()
        }.padding(28).frame(width: 380).navigationTitle(L("设置"))
    }
}
