import SwiftUI
import UserNotifications
import ContextCore

@main struct NovaContextApp: App {
    @NSApplicationDelegateAdaptor(DemoDelegate.self) var delegate
    @StateObject private var model = WorkspaceModel()
    @StateObject private var vault = CredentialVaultModel()
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("appearance") private var appearance = "system"
    init() {
        if CommandLine.arguments.dropFirst().contains("--agent") {
            DispatchQueue.global(qos: .userInitiated).async { exit(NativeGrantClient.run()) }
            dispatchMain()
        }
    }
    var body: some Scene {
        WindowGroup(L("归记")) {
            WorkspaceView(model: model, vault: vault, servicesReady: { delegate.services = $0 })
                .environment(\.locale, Locale(identifier: AppLanguage.resolve(preference: appLanguage).rawValue))
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onAppear {
                    delegate.model = model
                    delegate.vault = vault
                }
        }
        .defaultSize(width: 1380, height: 850)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("打开项目…")) { model.chooseProject() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("保存")) { Task { await model.saveDocument() } }
                    .keyboardShortcut("s").disabled(!model.isDirty || model.saving)
            }
            CommandGroup(replacing: .help) {
                Button(L("新手引导")) { NotificationCenter.default.post(name: AppHelp.onboarding, object: nil) }
                Button(L("使用手册")) { NotificationCenter.default.post(name: AppHelp.manual, object: nil) }
                Button(L("隐私政策")) { NotificationCenter.default.post(name: AppHelp.privacy, object: nil) }
                Button(L("使用条款")) { NotificationCenter.default.post(name: AppHelp.terms, object: nil) }
                Divider()
                Button(L("打开示例项目")) { model.openDemo() }
            }
            CommandMenu(L("编辑模式")) {
                Button(model.editing ? L("阅读文件") : L("编辑文件")) {
                    if model.editing { model.showReading() } else { model.beginEditing() }
                }.keyboardShortcut("e", modifiers: .command).disabled(!model.canEdit || model.saving)
            }
            CommandMenu(L("工作区")) {
                Button(L("刷新文件")) { model.refresh() }.keyboardShortcut("r")
                Button(L("导入并转换为 Markdown…")) { model.chooseConversion() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu(L("导航")) {
                Button(L("后退")) { model.goBack() }.keyboardShortcut("[", modifiers: .command).disabled(!model.canGoBack)
                Button(L("前进")) { model.goForward() }.keyboardShortcut("]", modifiers: .command).disabled(!model.canGoForward)
                Divider()
                Button(model.previewVisible ? L("收起分栏预览") : L("展开分栏预览")) { model.toggleSplitPreview() }
                    .keyboardShortcut("p", modifiers: [.command, .control]).disabled(!model.canShowSplitPreview || model.isFullScreen)
                Button(model.isFullScreen ? L("退出主视图全屏") : L("主视图全屏")) { model.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Button(model.sidebarVisible ? L("隐藏项目侧栏") : L("显示项目侧栏")) { model.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        Settings {
            LanguageSettingsView()
                .environment(\.locale, Locale(identifier: AppLanguage.resolve(preference: appLanguage).rawValue))
        }
    }
}

@MainActor final class DemoDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: WorkspaceModel? { didSet { openPendingFiles() } }
    private var pendingFiles: [URL] = []
    private var openingFiles = false
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFiles.append(contentsOf: urls)
        openPendingFiles()
    }
    private func openPendingFiles() {
        guard let model, !openingFiles, !pendingFiles.isEmpty else { return }
        openingFiles = true
        Task { @MainActor in
            while !pendingFiles.isEmpty {
                await model.openExternalFile(pendingFiles.removeFirst())
            }
            openingFiles = false
        }
    }
    weak var vault: CredentialVaultModel?
    weak var services: LocalServicesModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if services?.busy == true || vault?.busy == true || vault?.confirmDiscardEditor() == false { return .terminateCancel }
        guard let model else { return .terminateNow }
        if model.saving { return .terminateCancel }
        Task { @MainActor in
            model.performAfterEdits(
                {
                    Task { @MainActor in
                        await model.flushPreferences()
                        await self.vault?.flushReminders()
                        sender.reply(toApplicationShouldTerminate: true)
                    }
                }, cancelled: { sender.reply(toApplicationShouldTerminate: false) })
        }
        return .terminateLater
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        UNUserNotificationCenter.current().delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
