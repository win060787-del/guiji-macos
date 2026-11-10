import SwiftUI
import WebKit
import PDFKit
import ContextCore

enum Palette {
    static let paper = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.118, green: 0.114, blue: 0.106, alpha: 1) : NSColor(red: 0.992, green: 0.988, blue: 0.976, alpha: 1) })
    static let surface = Color.primary.opacity(0.035)
    static let accent = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.53, green: 0.78, blue: 0.69, alpha: 1) : NSColor(red: 0.16, green: 0.45, blue: 0.39, alpha: 1) })
    static let line = Color(nsColor: .separatorColor)
    static let secondary = Color.secondary
}

struct MarkdownView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let key = "\(colorScheme):\(text)"
        guard context.coordinator.last != key else { return }
        context.coordinator.last = key
        view.loadHTMLString(MarkdownRenderer.html(text), baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var last: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Reading must never trigger requests to remote images, scripts or links.
            decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
        }
    }
}

struct PDFReader: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}

struct LocalImage: View {
    @Environment(\.locale) private var locale
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { ScrollView([.vertical, .horizontal]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 900, maxHeight: 900).padding(24) } } else { ProgressView().controlSize(.small) }
        }.task(id: url) {
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            if let data { image = NSImage(data: data) }
        }
    }
}

struct SourceText: View {
    @Environment(\.locale) private var locale
    let text: String
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(26)
        }
    }
}

struct EmptyReader: View {
    @Environment(\.locale) private var locale
    let title: String
    var icon = "doc.text.magnifyingglass"
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(Palette.accent)
            if !title.isEmpty { Text(title).font(.system(size: 22, weight: .semibold)) }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ProjectFile {
    var icon: String {
        if isEnvironment { return "key.horizontal" }
        if isMarkdown { return "doc.text" }
        switch ext {
        case "pdf": return "doc.richtext"
        case "docx", "doc": return "doc.text.fill"
        case "xlsx", "xls", "csv": return "tablecells"
        case "pptx", "ppt": return "rectangle.on.rectangle"
        case "png", "jpg", "jpeg", "heic", "tiff": return "photo"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
    var category: String {
        if isEnvironment { return L("ENV · 值已隐藏") }
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }
}

struct LiveMarkdownPreview: View {
    @Environment(\.locale) private var locale
    let source: String
    @State private var rendered = ""
    var body: some View {
        MarkdownView(text: rendered)
            .task(id: source) {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                let snapshot = source
                let safe = await Task.detached(priority: .userInitiated) { SecretRedactor.redact(snapshot).text }.value
                guard !Task.isCancelled else { return }
                rendered = safe
            }
    }
}
