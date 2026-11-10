import XCTest
import AppKit
import ImageIO
@testable import ContextCore

final class OCRFallbackTests: XCTestCase {
    private func image() throws -> CGImage {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design/validation/ocr-benchmark-20261101/fixtures/english.png")
        guard let source = CGImageSourceCreateWithURL(fixture as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WorkspaceError.unreadable }
        return image
    }
    func testBundledLanguagesAndBlankImage() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design/validation/ocr-benchmark-20261101/fixtures")
        for (file, expected) in [("english", "Project"), ("zh-hans", "项目"), ("zh-hant", "憑證"), ("japanese", "設定"), ("spanish", "proyecto"), ("turkish", "Proje")] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(file + ".png") as CFURL, nil))
            let input = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let result = try TesseractRecognizer.recognize(input)
            XCTAssertTrue(result.filter { !$0.isWhitespace }.contains(expected), "\(file): \(result)")
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 400,height: 300))
        XCTAssertTrue(try TesseractRecognizer.recognize(XCTUnwrap(context.makeImage())).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    func testPrimaryResultDoesNotInvokeFallback() throws {
        let result = try OCRRecognizer.recognize(image(), primary: { _ in "primary" }, fallback: { _ in XCTFail("Unnecessary fallback"); return "" })
        XCTAssertEqual(result, "primary")
    }
    func testFailureAndEmptyResultUseNativeEngine() throws {
        let input = try image()
        for empty in [false, true] {
            let result = try OCRRecognizer.recognize(input, primary: { _ in if empty { return " \n" }; throw WorkspaceError.unreadable }, fallback: TesseractRecognizer.recognize)
            XCTAssertTrue(result.contains("Project"), result)
        }
        XCTAssertEqual(TesseractRecognizer.version, "5.5.3")
    }
    func testCancellationNeverInvokesFallback() throws {
        XCTAssertThrowsError(try OCRRecognizer.recognize(image(), primary: { _ in throw CancellationError() }, fallback: { _ in XCTFail("Cancelled recognition continued"); return "" })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testBothFailuresRemainVisible() throws {
        XCTAssertThrowsError(try OCRRecognizer.recognize(image(), primary: { _ in throw WorkspaceError.unreadable }, fallback: { _ in throw WorkspaceError.unreadable }))
    }
}
