import Foundation
#if canImport(FoundationXML)
    import FoundationXML
#endif
import PDFKit
import Vision
import ImageIO
import ZIPFoundation

public struct ConversionResult: Sendable {
    public let markdown: String
    public let warnings: [String]
    public let source: String
}

public enum DocumentConverter {
    public static func convert(_ url: URL) throws -> ConversionResult {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 50_000_000 else { throw WorkspaceError.tooLarge }
        try Task.checkCancellation()
        var warnings: [String] = []
        let body: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url), !document.isLocked else { throw WorkspaceError.unreadable }
            guard document.pageCount <= 40 else { throw WorkspaceError.limit(L("Demo 单次支持最多 40 页 PDF，请拆分后导入。")) }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { throw WorkspaceError.unreadable }
                var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty {
                    let image = page.thumbnail(of: NSSize(width: 1800, height: 2400), for: .mediaBox)
                    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw WorkspaceError.unreadable }
                    text = try recognize(cg)
                    warnings.append(L("第 \(index + 1) 页使用本机 OCR，请核对识别结果。"))
                }
                pages.append(L("## 第 \(index + 1) 页\n\n\(text.isEmpty ? L("[本页未识别到文字]") : text)"))
            }
            body = pages.joined(separator: "\n\n---\n\n")
            warnings.append(L("PDF 按页面提取文字，多栏顺序和复杂表格需核对；不保证还原版式。"))
        case "png", "jpg", "jpeg", "heic", "tiff", "bmp":
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { throw WorkspaceError.unreadable }
            body = try recognize(image)
            warnings.append(L("本机 OCR 提取文字；表格、手写字和阅读顺序需人工核对。多页图片仅处理第一帧。"))
        case "docx":
            let archive = try OfficeArchive(url)
            let root = try archive.xml("word/document.xml")
            guard let documentBody = root.descendants("body").first else { throw WorkspaceError.unreadable }
            body = documentBody.children.map { node in
                if node.name == "tbl" { return markdownTable(node.children.filter { $0.name == "tr" }.map { $0.children.filter { $0.name == "tc" }.map { $0.descendants("p").map(paragraph).joined(separator: "<br>") } }) }
                return node.name == "p" ? paragraph(node) : ""
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            warnings.append(L("保留正文、标题、列表与基础表格；批注、脚注、嵌入图片、复杂样式请查看原文件。"))
        case "pptx":
            let archive = try OfficeArchive(url)
            let presentation = try archive.xml("ppt/presentation.xml")
            let relationships = try archive.relations("ppt/_rels/presentation.xml.rels")
            let slides = presentation.descendants("sldId")
            guard slides.count <= 200 else { throw WorkspaceError.limit(L("Demo 最多转换 200 张幻灯片。")) }
            var sections: [String] = []
            for (index, slide) in slides.enumerated() {
                try Task.checkCancellation()
                guard let rid = slide.attributes["r:id"], let target = relationships[rid] else { throw WorkspaceError.unreadable }
                let root = try archive.xml(try OfficeArchive.resolve(target, base: "ppt"))
                let paragraphs = root.descendants("p").map { $0.descendants("t").map(\.text).joined() }.filter { !$0.isEmpty }
                sections.append(L("## 幻灯片 \(index + 1)\n\n") + paragraphs.joined(separator: "\n\n"))
            }
            body = sections.joined(separator: "\n\n---\n\n")
            warnings.append(L("按演示顺序提取幻灯片文字；图表、图片、动画与演讲者备注请查看原文件。"))
        case "xlsx":
            let archive = try OfficeArchive(url)
            let workbook = try archive.xml("xl/workbook.xml")
            let relationships = try archive.relations("xl/_rels/workbook.xml.rels")
            let shared: [String]
            if archive.has("xl/sharedStrings.xml") { shared = try archive.xml("xl/sharedStrings.xml").descendants("si").map { $0.descendants("t").map(\.text).joined() } } else { shared = [] }
            var sheets: [String] = []
            var totalCells = 0
            for sheet in workbook.descendants("sheet") {
                try Task.checkCancellation()
                guard let rid = sheet.attributes["r:id"], let target = relationships[rid] else { throw WorkspaceError.unreadable }
                let document = try archive.xml(try OfficeArchive.resolve(target, base: "xl"))
                var grid: [Int: [Int: String]] = [:]
                for row in document.descendants("row") {
                    for cell in row.children.filter({ $0.name == "c" }) {
                        totalCells += 1
                        guard totalCells <= 20_000 else { throw WorkspaceError.limit(L("Demo 单次最多转换 20,000 个单元格。")) }
                        let reference = cell.attributes["r"] ?? "A1"
                        let col = columnIndex(reference)
                        let rowNumber = Int(reference.filter(\.isNumber)) ?? 1
                        guard col < 100, rowNumber <= 5000 else { throw WorkspaceError.limit(L("工作表范围超过 Demo 上限：100 列、5000 行。")) }
                        let type = cell.attributes["t"] ?? ""
                        let raw = cell.descendants("v").first?.text ?? ""
                        let value: String
                        if type == "s", let i = Int(raw), shared.indices.contains(i) {
                            value = shared[i]
                        } else if type == "inlineStr" {
                            value = cell.descendants("t").map(\.text).joined()
                        } else if type == "b" {
                            value = raw == "1" ? "TRUE" : "FALSE"
                        } else {
                            value = raw.isEmpty && !cell.descendants("f").isEmpty ? L("[公式无缓存值]") : raw
                        }
                        grid[rowNumber, default: [:]][col] = value
                    }
                }
                let maxCol = grid.values.flatMap(\.keys).max() ?? 0
                var rows = [(0...maxCol).map { columnName($0) }]
                for index in grid.keys.sorted() { rows.append((0...maxCol).map { grid[index]?[$0] ?? "" }) }
                sheets.append(L("## 工作表：\(sheet.attributes["name"] ?? "Sheet")\n\n") + markdownTable(rows))
            }
            body = sheets.joined(separator: "\n\n")
            warnings.append(L("保留工作表与非空行的单元格；使用公式缓存值，不执行公式。日期可能显示 Excel 序列值，合并单元格与样式未还原。"))
        default: throw WorkspaceError.unsupported
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceError.empty }
        let safe = SecretRedactor.redact(body)
        if safe.count > 0 { warnings.append(L("已隐藏 \(safe.count) 处疑似敏感值。")) }
        let title = url.deletingPathExtension().lastPathComponent
        let output = L("# \(title)\n\n> 来源：\(url.lastPathComponent) · 本机转换 · 原文件保留\n\n") + warnings.map { "> \($0)" }.joined(separator: "\n") + "\n\n" + safe.text
        return ConversionResult(markdown: output, warnings: warnings, source: url.lastPathComponent)
    }
    static func recognize(_ image: CGImage) throws -> String {
        try OCRRecognizer.recognize(image)
    }
    static func paragraph(_ node: XMLNode) -> String {
        let content = node.descendants("t").map(\.text).joined()
        guard !content.isEmpty else { return "" }
        let style = node.descendants("pStyle").first?.attributes["w:val"] ?? ""
        if style.lowercased().hasPrefix("heading"), let n = Int(style.filter(\.isNumber)), (1...6).contains(n) { return String(repeating: "#", count: n) + " " + content }
        return (node.descendants("numPr").isEmpty ? "" : "- ") + content
    }
    static func columnIndex(_ reference: String) -> Int {
        reference.uppercased().prefix(while: \.isLetter).unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }
    static func columnName(_ index: Int) -> String {
        var n = index + 1, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
    static func markdownTable(_ rows: [[String]]) -> String {
        guard let first = rows.first, !first.isEmpty else { return "" }
        let width = rows.map(\.count).max() ?? first.count
        let formatted = rows.map { row in
            "| "
                + (0..<width).map { i in
                    (i < row.count ? row[i] : "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
                }.joined(separator: " | ") + " |"
        }
        return ([formatted[0], "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"] + formatted.dropFirst()).joined(separator: "\n")
    }
}

final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    func descendants(_ name: String) -> [XMLNode] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
}

final class XMLTree: NSObject, XMLParserDelegate {
    let root = XMLNode("root")
    var stack: [XMLNode] = []
    var nodes = 0
    init(_ data: Data) throws {
        super.init()
        stack = [root]
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw WorkspaceError.unreadable }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        nodes += 1
        guard stack.count < 128, nodes < 200_000 else { parser.abortParsing(); return }
        let node = XMLNode(elementName.components(separatedBy: ":").last ?? elementName, attributeDict)
        stack.last?.children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if stack.count > 1 { stack.removeLast() } }
}

final class OfficeArchive {
    let archive: Archive
    var extracted = 0
    init(_ url: URL) throws { archive = try Archive(url: url, accessMode: .read) }
    func has(_ path: String) -> Bool { archive[path] != nil }
    func xml(_ path: String) throws -> XMLNode {
        try Task.checkCancellation()
        guard let entry = archive[path], entry.type == .file, entry.uncompressedSize <= 10_000_000 else { throw WorkspaceError.unreadable }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= 10_000_000, self.extracted + chunk.count <= 32_000_000 else { throw WorkspaceError.tooLarge }
            data.append(chunk); self.extracted += chunk.count
        }
        return try XMLTree(data).root
    }
    func relations(_ path: String) throws -> [String: String] {
        let root = try xml(path)
        var values: [String: String] = [:]
        for relation in root.descendants("Relationship") where relation.attributes["TargetMode"] != "External" {
            if let id = relation.attributes["Id"], let target = relation.attributes["Target"] { values[id] = target }
        }
        return values
    }
    static func resolve(_ target: String, base: String) throws -> String {
        guard !target.contains("://"), !target.contains("\\") else { throw WorkspaceError.unreadable }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : base + "/" + target
        guard !path.split(separator: "/").contains("..") else { throw WorkspaceError.unreadable }
        return path
    }
}
