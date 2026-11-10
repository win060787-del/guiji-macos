import Foundation
import ContextCore
import AppKit
import PDFKit
@main struct Probe {
@MainActor static func main() {
 do {
 let dir = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/OCRProbe/ocr-" + UUID().uuidString)
 try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
 defer { try? FileManager.default.removeItem(at:dir) }
 let source = Bundle.main.url(forResource:"english",withExtension:"png")!
 let data = try Data(contentsOf:source)
 let png = dir.appendingPathComponent("image.png");try data.write(to:png)
 let scan = dir.appendingPathComponent("scan.pdf")
 try Data(contentsOf:Bundle.main.url(forResource:"scan",withExtension:"pdf")!).write(to:scan)
 print("prepared files:", FileManager.default.fileExists(atPath:png.path),FileManager.default.fileExists(atPath:scan.path))
 let first = try DocumentConverter.convert(png)
 print("after image:",FileManager.default.fileExists(atPath:dir.path),FileManager.default.fileExists(atPath:scan.path))
 let second = try DocumentConverter.convert(scan)
 let denied = (try? Data(contentsOf:URL(fileURLWithPath:ProcessInfo.processInfo.environment["PROBE_OUTSIDE"]!))) == nil
 let result:[String:Any] = ["imageRecognized":first.markdown.contains("Project"),"scannedPDFRecognized":second.markdown.contains("Project"),"outsideDenied":denied,"sourceUnchanged":try Data(contentsOf:png) == data]
 print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
 if !first.markdown.contains("Project") || !second.markdown.contains("Project") || !denied { exit(1) }
 } catch { print("ERROR: \(error)");exit(1) }
}
}
