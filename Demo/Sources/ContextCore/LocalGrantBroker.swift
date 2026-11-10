import Foundation

public struct GitHubIdentity: Codable, Equatable, Sendable {
  public let login: String
  public let id: Int
  public let type: String
  public init(login: String, id: Int, type: String) {
    self.login = login
    self.id = id
    self.type = type
  }
}
public protocol IdentityTransport: Sendable {
  func identity(secret: String) async throws -> GitHubIdentity
}
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
public final class GitHubIdentityAdapter: IdentityTransport, @unchecked Sendable {
  private let session: URLSession
  public static func accepts(_ address: String) -> Bool {
    guard let parts = URLComponents(string: address) else { return false }
    return parts.scheme == "https" && parts.host == "api.github.com"
      && (parts.path == "" || parts.path == "/")
      && parts.port == nil && parts.user == nil && parts.password == nil && parts.query == nil
      && parts.fragment == nil
  }
  public convenience init() { self.init(configuration: .ephemeral) }
  init(configuration: URLSessionConfiguration) {
    let config = configuration.copy() as! URLSessionConfiguration
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 15
    config.urlCache = nil
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  public func identity(secret: String) async throws -> GitHubIdentity {
    guard !secret.isEmpty, secret.utf8.count <= 8192,
      secret.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 })
    else { throw GrantError.credentialUnavailable }
    var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
    request.httpMethod = "GET"
    request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("NovaContext-LocalGrantService", forHTTPHeaderField: "User-Agent")
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        response.url?.absoluteString == request.url?.absoluteString
      else { throw GrantError.upstreamFailed }
      var data = Data()
      for try await byte in bytes {
        guard data.count < 65_536 else { throw GrantError.upstreamFailed }
        data.append(byte)
      }
      return try Self.decode(data, excluding: secret)
    } catch { throw GrantError.upstreamFailed }
  }
  public static func decode(_ data: Data, excluding secret: String) throws -> GitHubIdentity {
    guard data.count <= 65_536,
      let identity = try? JSONDecoder().decode(GitHubIdentity.self, from: data), identity.id > 0,
      identity.login.range(of: #"^[A-Za-z0-9-]{1,39}$"#, options: .regularExpression) != nil,
      ["User", "Organization", "Bot"].contains(identity.type),
      secret.isEmpty || (!identity.login.contains(secret) && !identity.type.contains(secret))
    else { throw GrantError.upstreamFailed }
    return identity
  }
}
public struct GrantRequest: Codable, Sendable {
  public let version: Int
  public let requestID: UUID
  public let token: String
  public let project: String
  public let operation: String
  public init(
    requestID: UUID = UUID(), token: String, project: String, operation: String = "github.identity"
  ) {
    version = 1
    self.requestID = requestID
    self.token = token
    self.project = project
    self.operation = operation
  }
}
public struct GrantResponse: Codable, Sendable {
  public let version: Int
  public let requestID: UUID?
  public let ok: Bool
  public let result: GitHubIdentity?
  public let error: String?
}
public actor LocalGrantBroker {
  private let grants: TemporaryGrantStore
  private let vault: CredentialVault
  private let transport: any IdentityTransport
  private var active = 0
  private var enabled = false
  public init(
    grants: TemporaryGrantStore, vault: CredentialVault,
    transport: any IdentityTransport = GitHubIdentityAdapter()
  ) {
    self.grants = grants
    self.vault = vault
    self.transport = transport
  }
  public func setEnabled(_ enabled: Bool) { self.enabled = enabled }
  public func handle(_ data: Data) async -> Data {
    var id: UUID?
    do {
      guard enabled, active < 4 else { throw GrantError.busy }
      guard data.count <= 4096 else { throw GrantError.invalidRequest }
      guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        Set(fields.keys) == Set(["version", "requestID", "token", "project", "operation"]),
        let request = try? JSONDecoder().decode(GrantRequest.self, from: data),
        request.version == 1,
        request.operation == "github.identity", request.project.utf8.count <= 1024
      else { throw GrantError.invalidRequest }
      id = request.requestID
      active += 1
      defer { active -= 1 }
      let grant = try await grants.validate(token: request.token, project: request.project)
      _ = try await vault.apiCredential(
        grant.credentialID, project: grant.project, revision: grant.credentialRevision)
      try await grants.reserve(grant.id, requestID: request.requestID)
      do {
        let secret: String
        do {
          secret = try await vault.authorizedAPISecret(
            grant.credentialID, project: grant.project, revision: grant.credentialRevision)
        } catch let error as GrantError { throw error } catch {
          throw GrantError.credentialUnavailable
        }
        // Recheck after Keychain access and before outbound execution; accepted/in-flight calls cannot be recalled.
        _ = try await grants.validate(token: request.token, project: request.project)
        guard enabled else { throw GrantError.busy }
        let result: GitHubIdentity
        do { result = try await transport.identity(secret: secret) } catch {
          throw GrantError.upstreamFailed
        }
        let safe = try GitHubIdentityAdapter.decode(JSONEncoder().encode(result), excluding: secret)
        try await grants.outcome(grant.id, "成功")
        return encode(GrantResponse(version: 1, requestID: id, ok: true, result: safe, error: nil))
      } catch {
        try? await grants.outcome(grant.id, "失败")
        throw error as? GrantError ?? .upstreamFailed
      }
    } catch {
      return encode(
        GrantResponse(
          version: 1, requestID: id, ok: false, result: nil,
          error: (error as? GrantError ?? .denied).rawValue))
    }
  }
  private func encode(_ response: GrantResponse) -> Data {
    (try? JSONEncoder().encode(response))
      ?? Data(#"{"version":1,"ok":false,"error":"denied"}"#.utf8)
  }
}
