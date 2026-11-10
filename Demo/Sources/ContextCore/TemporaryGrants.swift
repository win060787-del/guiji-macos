import CryptoKit
import Foundation
import Security

public enum GrantError: String, Error, LocalizedError, Sendable {
  case invalidRequest, denied, expired, revoked, credentialChanged, credentialUnavailable,
    upstreamFailed, duplicate, busy
  public var errorDescription: String? {
    switch self {
    case .invalidRequest: return L("请求格式或操作无效")
    case .denied: return L("授权无效或不属于此项目")
    case .expired: return L("授权已到期")
    case .revoked: return L("授权已作废")
    case .credentialChanged: return L("原凭证已变更，请重新创建授权")
    case .credentialUnavailable: return L("凭证不可用、已到期、未关联或服务地址不受支持")
    case .upstreamFailed: return L("API 请求失败，未返回原始响应")
    case .duplicate: return L("请求已处理，请勿重复执行")
    case .busy: return L("服务繁忙，请稍后重试")
    }
  }
}
public enum CredentialRevision {
  public static func of(_ record: CredentialRecord) -> String {
    let text = [
      record.id.uuidString, record.secretID?.uuidString ?? "", record.address, record.variable,
      String(record.updated.timeIntervalSince1970), record.environment,
    ].joined(separator: "\n")
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
public struct TemporaryGrant: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public let project: String
  public let credentialID: UUID
  public let credentialRevision: String
  public let createdAt: Date
  public var expiresAt: Date
  public var revokedAt: Date?
  public var tokenDigest: Data
  public var lastUsedAt: Date?
  public var requestIDs: [UUID]
  public var lastOutcome: String?
  public func status(at now: Date = Date()) -> String {
    revokedAt != nil ? L("已作废") : (expiresAt <= now ? L("已到期") : L("有效"))
  }
}
public struct IssuedGrant: Identifiable, Sendable {
  public var id: UUID { record.id }
  public let record: TemporaryGrant
  public let token: String
}
public actor TemporaryGrantStore {
  private let url: URL
  public init(url: URL) { self.url = url }
  public func records() throws -> [TemporaryGrant] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([TemporaryGrant].self, from: Data(contentsOf: url)).sorted {
      $0.createdAt > $1.createdAt
    }
  }
  private func write(_ records: [TemporaryGrant]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(records).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func token() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw GrantError.denied
    }
    return "nva_"
      + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  private static func digest(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }
  private static func equal(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
  public func issue(
    name: String, project: String, credential: CredentialRecord, days: Int, now: Date = Date(),
    replacing: UUID? = nil
  ) throws -> IssuedGrant {
    guard (1...365).contains(days), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      credential.kind == .api, credential.secretID != nil,
      credential.projects.contains(where: { $0.path == project }),
      credential.expiresAt.map({ $0 > now }) ?? true,
      GitHubIdentityAdapter.accepts(credential.address)
    else { throw GrantError.credentialUnavailable }
    var records = try records()
    guard records.count < 1000 else { throw GrantError.busy }
    if let replacing {
      guard
        let index = records.firstIndex(where: {
          $0.id == replacing && $0.project == project && $0.credentialID == credential.id
        })
      else { throw GrantError.denied }
      records[index].revokedAt = now
    }
    let token = try token()
    let expiry = min(
      now.addingTimeInterval(Double(days) * 86400), credential.expiresAt ?? .distantFuture)
    let record = TemporaryGrant(
      id: UUID(), name: String(name.prefix(100)), project: project, credentialID: credential.id,
      credentialRevision: CredentialRevision.of(credential), createdAt: now, expiresAt: expiry,
      revokedAt: nil,
      tokenDigest: Self.digest(token), lastUsedAt: nil, requestIDs: [], lastOutcome: nil)
    records.append(record)
    try write(records)
    return IssuedGrant(record: record, token: token)
  }
  public func validate(token: String, project: String, now: Date = Date()) throws -> TemporaryGrant
  {
    guard token.hasPrefix("nva_"), token.utf8.count == 47 else { throw GrantError.denied }
    let digest = Self.digest(token)
    guard let record = try records().first(where: { Self.equal($0.tokenDigest, digest) }),
      record.project == project
    else { throw GrantError.denied }
    guard record.revokedAt == nil else { throw GrantError.revoked }
    guard record.expiresAt > now else { throw GrantError.expired }
    return record
  }
  public func reserve(_ id: UUID, requestID: UUID, now: Date = Date()) throws {
    var records = try records()
    guard let index = records.firstIndex(where: { $0.id == id }), records[index].revokedAt == nil,
      records[index].expiresAt > now
    else { throw GrantError.denied }
    guard !records[index].requestIDs.contains(requestID) else { throw GrantError.duplicate }
    records[index].requestIDs.append(requestID)
    records[index].requestIDs = Array(records[index].requestIDs.suffix(128))
    records[index].lastUsedAt = now
    records[index].lastOutcome = "进行中"
    try write(records)
  }
  public func outcome(_ id: UUID, _ result: String) throws {
    var records = try records()
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].lastOutcome = result == "成功" ? "成功" : "失败"
    try write(records)
  }
  public func revoke(_ id: UUID, now: Date = Date()) throws {
    var records = try records()
    guard let index = records.firstIndex(where: { $0.id == id }) else { throw GrantError.denied }
    records[index].revokedAt = now
    try write(records)
  }
  public func remove(_ id: UUID, now: Date = Date()) throws {
    let records = try records()
    guard let record = records.first(where: { $0.id == id }),
      record.revokedAt != nil || record.expiresAt <= now
    else { throw GrantError.denied }
    try write(records.filter { $0.id != id })
  }
  public func revokeProject(_ project: String, now: Date = Date()) throws {
    var records = try records()
    for index in records.indices where records[index].project == project {
      records[index].revokedAt = now
    }
    try write(records)
  }
}
