import Foundation

/// Project-level, non-secret metadata. Credentials remain in CredentialVault.
public struct ProjectCard: Codable, Identifiable, Equatable, Sendable {
  public var path: String
  public var name: String
  public var environment: String
  public var runtime: String
  public var opened: Date
  public var id: String { path }
  public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
  public init(url: URL, opened: Date = Date()) {
    let root = url.standardizedFileURL.resolvingSymlinksInPath()
    path = root.path
    name = root.lastPathComponent
    environment = "开发"
    runtime = ""
    self.opened = opened
  }
}

public actor ProjectLibrary {
  private let url: URL
  public init(url: URL) { self.url = url }
  public func records() throws -> [ProjectCard] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([ProjectCard].self, from: Data(contentsOf: url))
      .sorted { $0.opened > $1.opened }
  }
  private func write(_ cards: [ProjectCard]) throws -> [ProjectCard] {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(cards).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return cards.sorted { $0.opened > $1.opened }
  }
  public func visit(_ root: URL) throws -> [ProjectCard] {
    var cards = try records()
    let card = ProjectCard(url: root)
    if let index = cards.firstIndex(where: { $0.path == card.path }) {
      cards[index].opened = card.opened
    } else {
      cards.append(card)
    }
    return try write(cards)
  }
  public func save(_ card: ProjectCard) throws -> [ProjectCard] {
    var cards = try records()
    guard let index = cards.firstIndex(where: { $0.path == card.path }) else {
      throw VaultError.invalid(L("项目已移除，请重新打开"))
    }
    // Do not let a stale configuration editor replace the last-opened timestamp.
    var updated = cards[index]
    updated.name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if updated.name.isEmpty { updated.name = card.url.lastPathComponent }
    updated.environment = card.environment
    updated.runtime = card.runtime.trimmingCharacters(in: .whitespacesAndNewlines)
    cards[index] = updated
    return try write(cards)
  }
  public func remove(_ path: String) throws -> [ProjectCard] {
    try write(records().filter { $0.path != path })
  }
}
