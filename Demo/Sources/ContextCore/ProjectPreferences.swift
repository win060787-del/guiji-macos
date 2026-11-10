import Foundation

public struct ProjectPreferences: Codable, Sendable {
    public var pins: Set<String>
    public var lastOpened: [String: Date]
    public var expandedFolders: Set<String>
    public init(pins: Set<String> = [], lastOpened: [String: Date] = [:], expandedFolders: Set<String> = []) {
        self.pins = pins; self.lastOpened = lastOpened; self.expandedFolders = expandedFolders
    }
    private enum CodingKeys: String, CodingKey { case pins, lastOpened, expandedFolders }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pins = try values.decodeIfPresent(Set<String>.self, forKey: .pins) ?? []
        lastOpened = try values.decodeIfPresent([String: Date].self, forKey: .lastOpened) ?? [:]
        expandedFolders = try values.decodeIfPresent(Set<String>.self, forKey: .expandedFolders) ?? []
    }
    /// Retired task/selection data gets one local backup before a clean preference file is written.
    public static func load(from url: URL) throws -> ProjectPreferences? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let preferences = try JSONDecoder().decode(Self.self, from: data)
        if let values = try JSONSerialization.jsonObject(with: data) as? [String: Any], values["task"] != nil || values["selected"] != nil {
            let backup = url.deletingPathExtension().appendingPathExtension("before-simplification.json")
            if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .withoutOverwriting) }
        }
        return preferences
    }
}
