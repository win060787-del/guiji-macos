import Foundation
import CMarkGFM
import MiaoYanCore

public enum MarkdownRenderer {
    public static func html(_ source: String) -> String {
        let body = Frontmatter.body(of: source)
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        body.withCString { cmark_parser_feed(parser, $0, body.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(rendered) }
        let html = String(cString: rendered)
        return """
            <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'"><style>
            :root{color-scheme:light dark;--paper:#fdfcf9;--ink:#363433;--muted:#858178;--line:#e8e6df;--code:#f3f1eb;--accent:#28786a}*{box-sizing:border-box}body{margin:0;padding:36px 42px 64px;background:var(--paper);color:var(--ink);font:15px/1.85 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}article{max-width:840px;margin:auto}h1{font-size:30px;line-height:1.35;letter-spacing:-.8px;margin:0 0 22px;font-weight:650}h2{font-size:21px;margin:32px 0 14px;font-weight:600;border-bottom:1px solid var(--line);padding-bottom:10px}h3{font-size:17px;margin-top:26px}p{margin:12px 0}a{color:var(--accent);text-decoration:none}blockquote{margin:20px 0;padding:2px 16px;border-left:3px solid #c6c2b5;color:var(--muted)}pre{padding:20px;background:var(--code);border:1px solid var(--line);border-radius:10px;overflow:auto;line-height:1.6}code{font:12px/1.7 ui-monospace,SFMono-Regular,monospace}p code,li code{background:var(--code);border-radius:4px;padding:3px 5px}table{display:block;max-width:100%;overflow:auto;border-collapse:collapse;font-size:13px;margin:20px 0}td,th{padding:10px 15px;border:1px solid var(--line);text-align:left;min-width:75px}th{background:var(--code)}hr{border:0;border-top:1px solid var(--line);margin:28px 0}li{margin:6px 0}input{accent-color:var(--accent)}@media(prefers-color-scheme:dark){:root{--paper:#1e1d1b;--ink:#e1ded7;--muted:#a9a49a;--line:#383630;--code:#292722;--accent:#8bbdaf}}@media(max-width:600px){body{padding:26px 24px}}
            </style></head><body><article>\(html)</article></body></html>
            """
    }
}
