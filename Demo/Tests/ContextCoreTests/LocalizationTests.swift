import XCTest
@testable import ContextCore

final class LocalizationTests: XCTestCase {
    func testPreferredLanguageResolutionAndEnglishFallback() {
        for (tag, expected) in [("zh-TW", AppLanguage.traditionalChinese), ("zh-HK", .traditionalChinese), ("zh-Hans-HK", .simplifiedChinese), ("zh-Hant-CN", .traditionalChinese), ("en-GB", .english), ("es-MX", .spanish), ("tr-TR", .turkish), ("ja-JP", .japanese)] {
            XCTAssertEqual(AppLanguage.resolve(preferredLanguages: [tag]), expected, tag)
        }
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "es-ES"]), .spanish)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "de-DE"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preference: "ja", preferredLanguages: ["en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.resolve(preference: "obsolete", preferredLanguages: ["tr"]), .turkish)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: []), .english)
    }
    func testCompleteCatalogAndPlaceholderParity() throws {
        let source = try XCTUnwrap(L10n.catalog["zh-Hans"])
        XCTAssertGreaterThan(source.count, 370)
        for language in AppLanguage.allCases {
            let values = try XCTUnwrap(L10n.catalog[language.rawValue])
            XCTAssertEqual(Set(values.keys), Set(source.keys), language.rawValue)
            for (key, value) in values {
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, key)
            }
        }
    }
    func testInterpolationPreservesUserContentAndFormattingTokens() {
        let name = "项目%@$HOME\\notes.md"
        for language in AppLanguage.allCases {
            let result = L10n.text("保存对“%@”的更改？", language: language, arguments: [name])
            XCTAssertTrue(result.contains(name), language.rawValue)
        }
        XCTAssertEqual(L10n.text("第 %@ 步，共 %@ 步", language: .english, arguments: ["1", "4"]), "Step 1 of 4")
        let literal: LocalizedText = "保存对“\(name)”的更改？"
        XCTAssertEqual(literal.key, "保存对“%@”的更改？")
        XCTAssertEqual(literal.arguments, [name])
    }
    func testEnglishCatalogHasNoChineseFallbackAndTraditionalTerminology() {
        for language in ["en", "es", "tr"] {
            for (key, value) in L10n.catalog[language]! {
                XCTAssertNil(value.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression), "\(language): \(key)")
            }
        }
        XCTAssertEqual(L10n.text("环境与凭证", language: .traditionalChinese), "環境與憑證")
        XCTAssertEqual(L10n.text("项目文件", language: .traditionalChinese), "專案檔案")
        XCTAssertEqual(L10n.text("本机钥匙串", language: .traditionalChinese), "本機鑰匙圈")
    }
    func testPersistenceIdentifiersStayLanguageIndependent() {
        XCTAssertEqual(CredentialKind.api.rawValue, "API 凭证")
        XCTAssertEqual(FileDateField.modified.rawValue, "修改日期")
        XCTAssertEqual(CredentialLifecycle.expired.rawValue, "已到期")
        XCTAssertEqual(ProjectCard(url: URL(fileURLWithPath: "/tmp/example")).environment, "开发")
        XCTAssertEqual(L10n.environment("custom-project-env"), "custom-project-env")
    }
}
