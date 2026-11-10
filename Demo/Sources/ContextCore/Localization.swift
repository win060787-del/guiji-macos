import Foundation

public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case english = "en", spanish = "es", turkish = "tr", japanese = "ja"
    public var id: String { rawValue }
    public var nativeName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .spanish: return "Español"
        case .turkish: return "Türkçe"
        case .japanese: return "日本語"
        }
    }
    public static func resolve(preference: String = "system", preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: preference) { return explicit }
        for tag in preferredLanguages {
            let parts = tag.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hant") { return .traditionalChinese }
                if parts.contains("hans") { return .simplifiedChinese }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
            }
            if let language = AppLanguage(rawValue: base) { return language }
        }
        return .english
    }
}

/// A literal and its arguments remain separate, so file names and user data are never translated.
public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
    }
}

public enum L10n {
    public static let preferenceKey = "appLanguage"
    public static var language: AppLanguage { AppLanguage.resolve(preference: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") }
    public static var locale: Locale { Locale(identifier: language.rawValue) }
    public static let catalog: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Localizations", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { preconditionFailure("Missing or invalid localization catalog") }
        return entries
    }()
    /// Only the three built-in environment labels are translated; custom labels are user data.
    public static func environment(_ value: String) -> String {
        ["开发", "测试", "生产"].contains(value) ? text(value) : value
    }
    public static func text(_ key: String, language: AppLanguage? = nil, arguments: [String] = []) -> String {
        let code = (language ?? self.language).rawValue
        let template = catalog[code]?[key] ?? catalog["en"]?[key] ?? key
        let pieces = template.components(separatedBy: "%@")
        guard pieces.count == arguments.count + 1 else { return template }
        return zip(arguments, pieces.dropFirst()).reduce(pieces[0]) { $0 + $1.0 + $1.1 }
    }
}
public func L(_ value: LocalizedText) -> String { L10n.text(value.key, arguments: value.arguments) }
