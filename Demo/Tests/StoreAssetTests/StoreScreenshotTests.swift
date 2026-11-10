import AppKit
import SwiftUI
import XCTest
import ImageIO
import UniformTypeIdentifiers
import ContextCore
@testable import NovaContext

private final class ScreenshotSecrets: CredentialSecretStore, @unchecked Sendable {
    func put(_ value: String, id: UUID) throws {}
    func get(id: UUID) throws -> String { throw VaultError.missing }
    func remove(id: UUID) throws {}
}

@MainActor final class StoreScreenshotTests: XCTestCase {
    func testFinderMarkdownOpenAndSaveWithoutScanningSiblings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("归记.md")
        try Data("# Finder document\n".utf8).write(to: file)
        try Data("untouched".utf8).write(to: root.appendingPathComponent("sibling.md"))
        let model = WorkspaceModel(dataDirectory: root.appendingPathComponent("state"))
        await model.openExternalFile(file)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.selection, "归记.md")
        XCTAssertEqual(model.files.map(\.name), ["归记.md"])
        for _ in 0..<100 where model.previewBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.previewBusy)
        model.beginEditing()
        for _ in 0..<100 where model.editorLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.editing)
        model.draft = "# Saved by 归记\n"
        let saved = await model.saveDocument()
        XCTAssertTrue(saved)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Saved by 归记\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sibling.md"), encoding: .utf8), "untouched")
    }
    func testNotificationStatusFollowsLanguageWithoutReloadingVault() async throws {
        let previous = UserDefaults.standard.string(forKey: L10n.preferenceKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.preferenceKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CredentialVault(url: root.appendingPathComponent("vault.json"), secrets: ScreenshotSecrets())
        let vault = CredentialVaultModel(repository: repository)
        await vault.load()
        await vault.flushReminders()
        for language in AppLanguage.allCases {
            UserDefaults.standard.set(language.rawValue, forKey: L10n.preferenceKey)
            XCTAssertEqual(vault.reminderStatus, L("需从应用启动通知服务"), language.rawValue)
        }
    }
    private func capture<V: View>(_ view: V, size: CGSize, name: String, output: URL, headings: [(String, String, String)], dark: Bool = false) async throws {
        let savedPreference = UserDefaults.standard.string(forKey: L10n.preferenceKey)
        defer {
            if let savedPreference { UserDefaults.standard.set(savedPreference, forKey: L10n.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.preferenceKey) }
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design/localization/captions.json")
        let captions = try JSONDecoder().decode([String: [[String]]].self, from: Data(contentsOf: source))
        let index = try XCTUnwrap(Int(name.prefix(2))) - 1
        for locale in ["zh-Hans", "zh-Hant", "en-US", "es-ES", "tr", "ja"] {
            let pair = try XCTUnwrap(captions[locale]?[index])
            let headline = pair[0], subtitle = pair[1]
            let language = AppLanguage.resolve(preferredLanguages: [locale])
            UserDefaults.standard.set(language.rawValue, forKey: L10n.preferenceKey)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, L10n.locale))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.backgroundColor = dark ? NSColor(calibratedWhite: 0.09, alpha: 1) : .white
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = window.appearance
        host.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw WorkspaceError.unreadable }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let raw = output.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: raw.appendingPathComponent(name + "-" + locale + ".png"))
        let image = NSImage(size: size); image.addRepresentation(bitmap)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: 2880, height: 1800, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw WorkspaceError.unreadable }
            context.scaleBy(x: 2, y: 2)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let background = dark ? NSColor(calibratedRed: 0.055, green: 0.095, blue: 0.09, alpha: 1) : NSColor(calibratedRed: 0.95, green: 0.955, blue: 0.935, alpha: 1)
            background.setFill(); NSRect(x: 0, y: 0, width: 1440, height: 900).fill()
            let foreground = dark ? NSColor.white : NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.20, alpha: 1)
            ("GUIJI  /  " + String(name.prefix(2)) as NSString).draw(in: NSRect(x: 56, y: 856, width: 1328, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: foreground])
            (headline as NSString).draw(in: NSRect(x: 56, y: 795, width: 1328, height: 54), withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: foreground])
            (subtitle as NSString).draw(in: NSRect(x: 56, y: 754, width: 1328, height: 34), withAttributes: [.font: NSFont.systemFont(ofSize: 19), .foregroundColor: foreground.withAlphaComponent(0.75)])
            let frame = NSRect(x: (1440 - size.width) / 2, y: 44, width: size.width, height: size.height)
            context.saveGState(); context.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor.black.withAlphaComponent(0.14).cgColor)
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill(); context.restoreGState()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).addClip()
            image.draw(in: frame); NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = context.makeImage(), let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + "-" + locale + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw WorkspaceError.unreadable }
            CGImageDestinationAddImage(destination, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
    func testOptInExportProductionViews() async throws {
        guard ProcessInfo.processInfo.environment["NOVA_CAPTURE_STORE"] == "1" else { throw XCTSkip("Explicit offline store asset capture") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["NOVA_STORE_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/tmp/NovaContextStore-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("墨舟网站")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let readme = """
        # 墨舟 · 项目工作区

        ## 本周计划

        - [x] 整理项目结构与文档
        - [x] 配置开发与生产环境
        - [ ] 完成首页与订阅流程
        - [ ] 更新部署说明

        ## 工作目录

        | 目录 | 用途 |
        | --- | --- |
        | web | 网站界面 |
        | api | 后端服务 |
        | docs | 需求与开发记录 |

        ## 运行环境

        Node.js 22 · Python 3.12

        项目配置与密钥分别管理。
        环境说明不包含原始 Token。
        """
        try Data(readme.utf8).write(to: project.appendingPathComponent("README.md"))
        try Data("# 发布清单\n\n- [ ] 检查环境\n- [ ] 核对变更\n".utf8).write(to: project.appendingPathComponent("docs/发布清单.md"))
        try Data(#"{"engines":{"node":">=22"}}"#.utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("GITHUB_TOKEN=\nAPI_BASE_URL=\nDATABASE_URL=\n".utf8).write(to: project.appendingPathComponent(".env.example"))
        let libraryURL = root.appendingPathComponent("cards.json"), library = ProjectLibraryModel(url: libraryURL)
        var first = ProjectCard(url: project); first.opened = Date().addingTimeInterval(60); first.name = "墨舟 · 网站"; first.environment = "开发"; first.runtime = "Node.js 22"
        var second = ProjectCard(url: URL(fileURLWithPath: "/Users/demo/Projects/reader")); second.name = "清读 · 阅读器"; second.runtime = "Swift Package"
        var third = ProjectCard(url: URL(fileURLWithPath: "/Users/demo/Projects/research")); third.name = "山海 · 数据分析"; third.runtime = "Python 3.12"; third.environment = "测试"
        try JSONEncoder().encode([first, second, third]).write(to: libraryURL)
        await library.load(); await library.inspect(project)
        let repository = CredentialVault(url: root.appendingPathComponent("vault.json"), secrets: ScreenshotSecrets())
        var api = CredentialRecord(); api.name = "GitHub 开发凭证"; api.address = "https://api.github.com"; api.provider = "GitHub"; api.variable = "GITHUB_TOKEN"; api.projects = [CredentialProject(url: project)]
        api.expiresAt = Date().addingTimeInterval(6 * 86400); api.rotateAt = Date().addingTimeInterval(4 * 86400)
        _ = try await repository.save(api, secret: "synthetic-screen-only-value")
        var server = CredentialRecord(); server.kind = .server; server.name = "网站生产环境"; server.address = "app.example.com"; server.username = "deploy"; server.keyPath = "~/.ssh/project_key"; server.deployPath = "/srv/mozhoo"; server.environment = "生产"; server.projects = [CredentialProject(url: project)]
        _ = try await repository.save(server, secret: nil)
        let vault = CredentialVaultModel(repository: repository); await vault.load(); vault.selection = api.id
        let cards = ProjectCardsView(library: library, vault: vault, open: { _ in }, add: {}, manageCredentials: { _ in }, exportBrief: { _ in }, manageAuthorizations: { _ in }, removeProject: { _ in })
        try await capture(cards, size: CGSize(width: 1152, height: 660), name: "01-projects", output: output, headings: [("zh-Hans", "每个项目，一目了然", "文件、运行环境、ENV 与后端配置，归到同一张卡片。"), ("en-US", "Every project, in one place.", "Files, environments and credential links, organized together.")])
        let model = WorkspaceModel(dataDirectory: root.appendingPathComponent("workspace-data")); model.load(project)
        for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.select("README.md")
        for _ in 0..<100 { if !model.previewBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.beginEditing()
        for _ in 0..<100 { if !model.editorLoading { break }; try await Task.sleep(for: .milliseconds(20)) }
        let workspace = WorkspaceView(model: model, vault: vault, library: library, showingProjects: false)
        try await capture(workspace, size: CGSize(width: 1328, height: 660), name: "02-editor", output: output, headings: [("zh-Hans", "找到文件，接着写", "目录分层管理，Markdown 与代码原地编辑，⌘S 保存。"), ("en-US", "Find the file. Keep writing.", "Browse folders, edit Markdown and code, then save with Command-S.")])
        let detail = CredentialVaultView(vault: vault, project: project)
        try await capture(detail, size: CGSize(width: WorkspaceDialog.width, height: WorkspaceDialog.height), name: "03-vault", output: output, headings: [("zh-Hans", "凭证有归属，也有期限", "钥匙串保存原始 Key，项目关联与到期日期清晰可见。"), ("en-US", "Keep keys linked, not scattered.", "Keychain storage, project links and credential expiry dates.")])
        let services = LocalServicesModel(vault: repository, directory: root.appendingPathComponent("services")); services.project = project.path
        await services.create(credentialID: api.id, days: 7, name: "网站开发 · GitHub 只读")
        services.issued = nil
        let serviceView = LocalServicesView(services: services, vault: vault, projects: library.cards)
        try await capture(serviceView, size: CGSize(width: 740, height: 620), name: "04-access", output: output, headings: [("zh-Hans", "给 AI 临时授权，不交出原始 Key", "限定项目与有效期，随时作废；首个支持 GitHub 只读操作。"), ("en-US", "Temporary access. Original keys stay put.", "Project-scoped, revocable access. Starts with a read-only GitHub operation.")])
        try await capture(OnboardingView(model: model, finish: { _ in }), size: CGSize(width: 740, height: 610), name: "05-onboarding", output: output, headings: [("zh-Hans", "从一个项目开始", "选择文件夹与外观，凭证和本机服务按需启用。"), ("en-US", "Start with one project.", "Choose a folder and appearance. Enable credentials and services when needed.")])
    }
}
