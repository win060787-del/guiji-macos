import Foundation

public enum ScanCapacity: String, CaseIterable, Codable, Sendable {
    case standard = "20000", expanded = "50000", maximum = "100000"
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .maximum
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        if !defaults.bool(forKey: "indexCapacity100kDefault") {
            defaults.set(Self.maximum.rawValue, forKey: "indexCapacity")
            defaults.set(true, forKey: "indexCapacity100kDefault")
        }
        return Self(storedValue: defaults.string(forKey: "indexCapacity"))
    }
    public var maxFiles: Int {
        switch self {
        case .standard: return 20_000
        case .expanded: return 50_000
        case .maximum: return 100_000
        }
    }
    public var maxEntries: Int { maxFiles * 4 }
    public var title: String {
        switch self {
        case .standard: return L("2 万文件 · 8 万目录项")
        case .expanded: return L("5 万文件 · 20 万目录项")
        case .maximum: return L("10 万文件 · 40 万目录项")
        }
    }
}
