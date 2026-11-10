import CoreGraphics
import Foundation
import NativeOCR
import Vision

/// Both engines receive only the current rasterized page. No child process or network access.
enum OCRRecognizer {
    static func recognize(_ image: CGImage) throws -> String {
        try recognize(image, primary: vision, fallback: TesseractRecognizer.recognize)
    }
    static func recognize(_ image: CGImage, primary: (CGImage) throws -> String,
                          fallback: (CGImage) throws -> String) throws -> String {
        try Task.checkCancellation()
        do {
            let text = try primary(image)
            try Task.checkCancellation()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation() }
        let text = try fallback(image)
        try Task.checkCancellation()
        return text
    }
    private static func vision(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "es-ES", "tr-TR"].filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

enum TesseractRecognizer {
    static let languages = ["eng", "chi_sim", "chi_tra", "jpn", "spa", "tur"]
    static var version: String { String(cString: NovaOCRVersion()) }
    static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let directory = Bundle.module.url(forResource: "tessdata", withExtension: nil, subdirectory: "Resources"),
              languages.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".traineddata").path) })
        else { throw WorkspaceError.unreadable }
        let stride = width * 4
        var pixels = [UInt8](repeating: 255, count: stride * height)
        let text: String = try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw WorkspaceError.unreadable }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let output = NovaOCRRecognizeRGBA(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    Int32(width), Int32(height), Int32(stride), directory.path, languages.joined(separator: "+"))
            else { throw WorkspaceError.unreadable }
            defer { NovaOCRFreeText(output) }
            return String(cString: output)
        }
        try Task.checkCancellation()
        return text
    }
}
