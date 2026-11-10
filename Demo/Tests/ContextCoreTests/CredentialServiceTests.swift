import Darwin
import XCTest

@testable import ContextCore

private final class ServiceSecrets: CredentialSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: String] = [:]
  func put(_ value: String, id: UUID) throws {
    lock.lock()
    values[id] = value
    lock.unlock()
  }
  func get(id: UUID) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values[id] else { throw VaultError.missing }
    return value
  }
  func remove(id: UUID) throws {
    lock.lock()
    values[id] = nil
    lock.unlock()
  }
}
private actor FakeIdentity: IdentityTransport {
  var calls = 0
  var matched = true
  let fails: Bool
  init(fails: Bool = false) { self.fails = fails }
  func identity(secret: String) async throws -> GitHubIdentity {
    calls += 1
    matched = matched && secret == "synthetic-original-api-key"
    if fails { throw VaultError.invalid("synthetic-original-api-key") }
    return GitHubIdentity(login: "synthetic-user", id: 42, type: "User")
  }
}
final class CredentialServiceTests: XCTestCase {
  private func directory() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/nvs-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func credential(_ root: URL) -> CredentialRecord {
    var record = CredentialRecord()
    record.name = "Synthetic GitHub"
    record.address = "https://api.github.com"
    record.variable = "GITHUB_TOKEN"
    record.projects = [CredentialProject(url: root)]
    record.secretID = UUID()
    return record
  }
  private func fixture() async throws -> (
    URL, CredentialVault, CredentialRecord, TemporaryGrantStore
  ) {
    let dir = try directory()
    let secrets = ServiceSecrets()
    let vault = CredentialVault(url: dir.appendingPathComponent("vault.json"), secrets: secrets)
    _ = try await vault.save(credential(dir), secret: "synthetic-original-api-key")
    let record = try await vault.records()[0]
    return (dir, vault, record, TemporaryGrantStore(url: dir.appendingPathComponent("grants.json")))
  }
  func testNativeAgentClientUsesScopedServiceAndReflectsRevocation() async throws {
    let (dir, vault, record, grants) = try await fixture()
    let issued = try await grants.issue(name: "Native test", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: grants, vault: vault, transport: FakeIdentity())
    await broker.setEnabled(true)
    let service = LocalSocketService(url: dir.appendingPathComponent("api.sock"), broker: broker)
    try service.start(); defer { service.stop() }
    let grant = try JSONSerialization.data(withJSONObject: ["version": 1, "socket": service.url.path, "project": dir.path, "operation": "github.identity", "token": issued.token])
    let requestID = UUID()
    let response = try await Task.detached { try NativeGrantClient.request(grant, requestID: requestID) }.value
    let decoded = try JSONDecoder().decode(GrantResponse.self, from: response)
    XCTAssertTrue(decoded.ok); XCTAssertEqual(decoded.result?.login, "synthetic-user")
    XCTAssertFalse(String(decoding: response, as: UTF8.self).contains("synthetic-original-api-key"))
    XCTAssertFalse(String(decoding: response, as: UTF8.self).contains(issued.token))
    let duplicate = try await Task.detached { try NativeGrantClient.request(grant, requestID: requestID) }.value
    XCTAssertEqual(try JSONDecoder().decode(GrantResponse.self, from: duplicate).error, "duplicate")
    try await grants.revoke(issued.record.id)
    let revoked = try await Task.detached { try NativeGrantClient.request(grant) }.value
    XCTAssertEqual(try JSONDecoder().decode(GrantResponse.self, from: revoked).error, "revoked")
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: service.url.path)
    XCTAssertThrowsError(try NativeGrantClient.request(grant))
  }
  func testNativeClientRejectsOversizedAndUnsupportedInputs() throws {
    XCTAssertThrowsError(try NativeGrantClient.request(Data(repeating: 32, count: 16385)))
    let unsupported = try JSONSerialization.data(withJSONObject: ["version": 1, "socket": "/tmp/unused.sock", "project": "/tmp/project", "operation": "shell.exec", "token": "nva_" + String(repeating: "a", count: 43)])
    XCTAssertThrowsError(try NativeGrantClient.request(unsupported))
  }
  func testLegacyDatesRemainUnknownAndSavePreservesAddedDate() async throws {
    let (dir, vault, record, _) = try await fixture()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    for key in ["addedAt", "expiresAt", "rotateAt", "remindersEnabled", "reminderDays"] {
      object.removeValue(forKey: key)
    }
    let old = try JSONDecoder().decode(
      CredentialRecord.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(old.addedAt)
    XCTAssertNil(old.remindersEnabled)
    let original = record.addedAt
    var changed = record
    changed.name = "Changed"
    _ = try await vault.save(changed, secret: nil)
    let saved = try await vault.records()[0]
    XCTAssertEqual(saved.addedAt, original)
    XCTAssertFalse(
      try String(contentsOf: dir.appendingPathComponent("vault.json"), encoding: .utf8).contains(
        "synthetic-original-api-key"))
  }
  func testReminderPlanDatesStableIDsAndCancellation() throws {
    let root = try directory()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var record = credential(root)
    record.remindersEnabled = true
    record.expiresAt = now.addingTimeInterval(8 * 86400)
    record.reminderDays = [7, 1, 0, 7, -1, 999]
    let plan = CredentialReminderPlan.make(
      [record], now: now, calendar: Calendar(identifier: .gregorian))
    XCTAssertEqual(plan.count, 3)
    XCTAssertEqual(Set(plan.map(\.id)).count, 3)
    XCTAssertTrue(plan.allSatisfy { $0.date > now })
    let ids = plan.map(\.id)
    record.expiresAt = now.addingTimeInterval(9 * 86400)
    XCTAssertEqual(Set(CredentialReminderPlan.make([record], now: now).map(\.id)), Set(ids))
    record.remindersEnabled = false
    XCTAssertTrue(CredentialReminderPlan.make([record], now: now).isEmpty)
    XCTAssertTrue(CredentialReminderPlan.make([], now: now).isEmpty)
    record.expiresAt = now
    XCTAssertEqual(record.lifecycle(at: now), .expired)
    record.expiresAt = nil
    record.rotateAt = now
    XCTAssertEqual(record.lifecycle(at: now), .rotationDue)
    record.rotateAt = now.addingTimeInterval(86400)
    XCTAssertEqual(record.lifecycle(at: now), .soon)
  }
  func testIssuanceOnlyPersistsDigestAndExpiryIsCapped() async throws {
    let (dir, _, original, store) = try await fixture()
    var record = original
    let now = Date()
    record.expiresAt = now.addingTimeInterval(3600)
    let issued = try await store.issue(
      name: "Test", project: dir.path, credential: record, days: 30, now: now)
    XCTAssertEqual(issued.record.expiresAt, record.expiresAt)
    XCTAssertEqual(issued.token.utf8.count, 47)
    let valid = try await store.validate(token: issued.token, project: dir.path, now: now)
    XCTAssertEqual(valid.id, issued.id)
    let data = try Data(contentsOf: dir.appendingPathComponent("grants.json"))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(issued.token))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-original-api-key"))
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: dir.appendingPathComponent("grants.json").path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    do {
      _ = try await store.validate(
        token: issued.token, project: dir.path, now: now.addingTimeInterval(3600))
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .expired) }
    do {
      _ = try await store.validate(token: issued.token, project: "/wrong", now: now)
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .denied) }
  }
  func testRevocationRotationAndProjectIsolation() async throws {
    let (dir, _, record, store) = try await fixture()
    let a = try await store.issue(name: "A", project: dir.path, credential: record, days: 7)
    let b = try await store.issue(
      name: "B", project: dir.path, credential: record, days: 7, replacing: a.id)
    XCTAssertNotEqual(a.token, b.token)
    do {
      _ = try await store.validate(token: a.token, project: dir.path)
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .revoked) }
    try await store.revokeProject(dir.path)
    do {
      _ = try await store.validate(token: b.token, project: dir.path)
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .revoked) }
    try await store.remove(a.id)
    let remaining = try await store.records()
    XCTAssertEqual(remaining.count, 1)
  }
  func testBrokerEndToEndAndReplayRevocation() async throws {
    let (dir, vault, record, store) = try await fixture()
    let transport = FakeIdentity()
    let grant = try await store.issue(name: "Agent", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: transport)
    await broker.setEnabled(true)
    let request = GrantRequest(token: grant.token, project: dir.path)
    let input = try JSONEncoder().encode(request)
    let output = await broker.handle(input)
    let reply = try JSONDecoder().decode(GrantResponse.self, from: output)
    XCTAssertTrue(reply.ok)
    XCTAssertEqual(reply.result?.login, "synthetic-user")
    XCTAssertFalse(String(decoding: output, as: UTF8.self).contains(grant.token))
    XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("synthetic-original-api-key"))
    let replay = try JSONDecoder().decode(GrantResponse.self, from: await broker.handle(input))
    XCTAssertEqual(replay.error, GrantError.duplicate.rawValue)
    try await store.revoke(grant.id)
    let revoked = try JSONDecoder().decode(
      GrantResponse.self,
      from: await broker.handle(
        JSONEncoder().encode(GrantRequest(token: grant.token, project: dir.path))))
    XCTAssertEqual(revoked.error, GrantError.revoked.rawValue)
    let count = await transport.calls
    let matched = await transport.matched
    XCTAssertEqual(count, 1)
    XCTAssertTrue(matched)
  }
  func testScopeModificationExpiryAndInvalidOperationsNeverReachAPI() async throws {
    let (dir, vault, record, store) = try await fixture()
    let transport = FakeIdentity()
    let grant = try await store.issue(name: "Agent", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: transport)
    await broker.setEnabled(true)
    for request in [
      GrantRequest(token: grant.token, project: "/other"),
      GrantRequest(token: grant.token, project: dir.path, operation: "arbitrary.url"),
    ] {
      let reply = try JSONDecoder().decode(
        GrantResponse.self, from: await broker.handle(JSONEncoder().encode(request)))
      XCTAssertFalse(reply.ok)
    }
    var changed = record
    changed.address = "https://example.invalid"
    _ = try await vault.save(changed, secret: nil)
    let rejected = try JSONDecoder().decode(
      GrantResponse.self,
      from: await broker.handle(
        JSONEncoder().encode(GrantRequest(token: grant.token, project: dir.path))))
    XCTAssertFalse(rejected.ok)
    let calls = await transport.calls
    XCTAssertEqual(calls, 0)
  }
  func testUpstreamErrorAndResponseAreSanitized() async throws {
    let (dir, vault, record, store) = try await fixture()
    let grant = try await store.issue(name: "Agent", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: FakeIdentity(fails: true))
    await broker.setEnabled(true)
    let output = await broker.handle(
      try JSONEncoder().encode(GrantRequest(token: grant.token, project: dir.path)))
    XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("synthetic-original-api-key"))
    XCTAssertEqual(
      try JSONDecoder().decode(GrantResponse.self, from: output).error, "upstreamFailed")
    let raw = Data(
      #"{"login":"demo","id":1,"type":"User","token":"synthetic-original-api-key","email":"private@example.invalid"}"#
        .utf8)
    let safe = try GitHubIdentityAdapter.decode(raw, excluding: "synthetic-original-api-key")
    let text = String(decoding: try JSONEncoder().encode(safe), as: UTF8.self)
    XCTAssertFalse(text.contains("token"))
    XCTAssertFalse(text.contains("email"))
    for address in [
      "http://api.github.com", "https://api.github.com.evil.invalid", "https://api.github.com:443",
      "https://api.github.com/user", "https://user:password@api.github.com",
      "https://api.github.com?token=secret",
    ] { XCTAssertFalse(GitHubIdentityAdapter.accepts(address)) }
  }
  func testCorruptAuthorizationStoreFailsClosed() async throws {
    let (dir, _, record, store) = try await fixture()
    let file = dir.appendingPathComponent("grants.json")
    let original = Data("broken".utf8)
    try original.write(to: file)
    do {
      _ = try await store.issue(name: "X", project: dir.path, credential: record, days: 7)
      XCTFail()
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), original)
  }
  func testPrivateExportNeverOverwritesOrFollowsSymlinks() throws {
    let dir = try directory()
    let file = dir.appendingPathComponent("grant.json")
    let link = dir.appendingPathComponent("link.json")
    try PrivateFile.writeNew(Data("first".utf8), to: file)
    XCTAssertThrowsError(try PrivateFile.writeNew(Data("second".utf8), to: file))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(try PrivateFile.writeNew(Data("second".utf8), to: link))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")
  }
  private static func socketCall(_ url: URL, _ data: Data) throws -> Data {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GrantError.busy }
    defer { Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
    let connected = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw GrantError.busy }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var request = data
    request.append(10)
    _ = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while response.count < 16384 {
      let count = Darwin.recv(fd, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      response.append(contentsOf: buffer.prefix(count))
      if response.contains(10) { return Data(response.prefix(while: { $0 != 10 })) }
    }
    throw GrantError.invalidRequest
  }
  func testPrivateSocketEndToEndStopAndRestart() async throws {
    let (dir, vault, record, store) = try await fixture()
    let issued = try await store.issue(
      name: "Socket", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: FakeIdentity())
    await broker.setEnabled(true)
    let path = dir.appendingPathComponent("service/api.sock")
    let server = LocalSocketService(url: path, broker: broker)
    try server.start()
    defer { server.stop() }
    let second = LocalSocketService(url: path, broker: broker)
    XCTAssertThrowsError(try second.start())
    let mode =
      try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    let input = try JSONEncoder().encode(GrantRequest(token: issued.token, project: dir.path))
    let data = try await Task.detached { try Self.socketCall(path, input) }.value
    XCTAssertTrue(try JSONDecoder().decode(GrantResponse.self, from: data).ok)
    try await store.revoke(issued.id)
    let denied = try await Task.detached {
      try Self.socketCall(
        path, JSONEncoder().encode(GrantRequest(token: issued.token, project: dir.path)))
    }.value
    XCTAssertEqual(try JSONDecoder().decode(GrantResponse.self, from: denied).error, "revoked")
    await broker.setEnabled(false)
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    try server.start()
    server.stop()
  }
  func testPackagedPythonClientWithFakeAPI() async throws {
    let (dir, vault, record, store) = try await fixture()
    let issued = try await store.issue(
      name: "Client", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: FakeIdentity())
    await broker.setEnabled(true)
    let path = dir.appendingPathComponent("service/api.sock")
    let server = LocalSocketService(url: path, broker: broker)
    try server.start()
    defer { server.stop() }
    let grantFile = dir.appendingPathComponent("agent.json")
    let object: [String: Any] = [
      "version": 1, "socket": path.path, "project": dir.path, "operation": "github.identity",
      "token": issued.token,
    ]
    try PrivateFile.writeNew(JSONSerialization.data(withJSONObject: object), to: grantFile)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "scripts/nova-agent.py")
    func run() async throws -> (Int32, String) {
      try await Task.detached {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", source.path, "--grant", grantFile.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
      }.value
    }
    let first = try await run()
    XCTAssertEqual(first.0, 0)
    XCTAssertTrue(first.1.contains("synthetic-user"))
    XCTAssertFalse(first.1.contains(issued.token))
    try await store.revoke(issued.id)
    let second = try await run()
    XCTAssertEqual(second.0, 1)
    XCTAssertTrue(second.1.contains("revoked"))
  }
}

private final class InterceptGitHub: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  static var status = 200
  static var body = Data()
  static var requests: [URLRequest] = []
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    let status = Self.status
    let body = Self.body
    Self.lock.unlock()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
  static func reset(status: Int, body: Data) {
    lock.lock()
    self.status = status
    self.body = body
    requests = []
    lock.unlock()
  }
  static func captured() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}
extension CredentialServiceTests {
  func testRealHTTPAdapterContractWithoutNetwork() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [InterceptGitHub.self]
    let adapter = GitHubIdentityAdapter(configuration: config)
    InterceptGitHub.reset(
      status: 200,
      body: Data(
        #"{"login":"http-test","id":7,"type":"User","email":"private@example.invalid","token":"synthetic-key"}"#
          .utf8))
    let identity = try await adapter.identity(secret: "synthetic-key")
    XCTAssertEqual(identity.login, "http-test")
    let request = try XCTUnwrap(InterceptGitHub.captured().first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
    XCTAssertNil(request.httpBody)
    for status in [301, 302, 401, 429, 500] {
      InterceptGitHub.reset(status: status, body: Data("synthetic-key".utf8))
      do {
        _ = try await adapter.identity(secret: "synthetic-key")
        XCTFail()
      } catch { XCTAssertEqual(error as? GrantError, .upstreamFailed) }
    }
    InterceptGitHub.reset(status: 200, body: Data(repeating: 32, count: 65537))
    do {
      _ = try await adapter.identity(secret: "synthetic-key")
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .upstreamFailed) }
  }
  func testKeyRotationUnlinkAndCredentialExpiryInvalidateGrant() async throws {
    let (dir, vault, original, store) = try await fixture()
    let grant = try await store.issue(name: "Old", project: dir.path, credential: original, days: 1)
    _ = try await vault.save(original, secret: "synthetic-new-key")
    do {
      _ = try await vault.authorizedAPISecret(
        original.id, project: dir.path, revision: grant.record.credentialRevision)
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .credentialChanged) }
    let current = try await vault.apiCredential(original.id, project: dir.path)
    _ = try await vault.link(current.id, project: CredentialProject(url: dir), linked: false)
    do {
      _ = try await vault.apiCredential(original.id, project: dir.path)
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .credentialUnavailable) }
    var expired = current
    expired.expiresAt = Date().addingTimeInterval(-1)
    _ = try await vault.save(expired, secret: nil)
    do {
      _ = try await vault.apiCredential(original.id, project: dir.path)
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .credentialUnavailable) }
  }
  func testSocketRejectsOversizedMalformedAndUnknownFields() async throws {
    let (dir, vault, _, store) = try await fixture()
    let transport = FakeIdentity()
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: transport)
    await broker.setEnabled(true)
    for data in [
      Data(repeating: 120, count: 4097), Data("not JSON".utf8),
      Data(#"{"version":1,"url":"https://evil.invalid"}"#.utf8),
    ] {
      let response = try JSONDecoder().decode(GrantResponse.self, from: await broker.handle(data))
      XCTAssertFalse(response.ok)
    }
    let calls = await transport.calls
    XCTAssertEqual(calls, 0)
  }
}

private actor PausedIdentity: IdentityTransport {
  var calls = 0
  var continuations: [CheckedContinuation<Void, Never>] = []
  func identity(secret: String) async throws -> GitHubIdentity {
    calls += 1
    await withCheckedContinuation { continuations.append($0) }
    return GitHubIdentity(login: "paused-test", id: 9, type: "User")
  }
  func release() {
    let pending = continuations
    continuations = []
    pending.forEach { $0.resume() }
  }
}
extension CredentialServiceTests {
  func testRevokingAnInFlightCallBlocksFollowingCalls() async throws {
    let (dir, vault, record, store) = try await fixture()
    let transport = PausedIdentity()
    let grant = try await store.issue(
      name: "In flight", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: transport)
    await broker.setEnabled(true)
    let input = try JSONEncoder().encode(GrantRequest(token: grant.token, project: dir.path))
    let first = Task { await broker.handle(input) }
    for _ in 0..<200 {
      if await transport.calls == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let count = await transport.calls
    XCTAssertEqual(count, 1)
    try await store.revoke(grant.id)
    let second = await broker.handle(
      try JSONEncoder().encode(GrantRequest(token: grant.token, project: dir.path)))
    XCTAssertEqual(try JSONDecoder().decode(GrantResponse.self, from: second).error, "revoked")
    await transport.release()
    let completed = await first.value
    XCTAssertTrue(try JSONDecoder().decode(GrantResponse.self, from: completed).ok)
  }
  func testRapidSocketRestartDoesNotConsumeNewGenerationRequests() async throws {
    let (dir, vault, record, store) = try await fixture()
    let grant = try await store.issue(
      name: "Restart", project: dir.path, credential: record, days: 1)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: FakeIdentity())
    await broker.setEnabled(true)
    let url = dir.appendingPathComponent("service/api.sock")
    let service = LocalSocketService(url: url, broker: broker)
    defer { service.stop() }
    for _ in 0..<15 {
      try service.start()
      let request = try JSONEncoder().encode(GrantRequest(token: grant.token, project: dir.path))
      let reply = try await Task.detached { try Self.socketCall(url, request) }.value
      XCTAssertTrue(try JSONDecoder().decode(GrantResponse.self, from: reply).ok)
      service.stop()
    }
  }
}
extension CredentialServiceTests {
  func testProjectRevocationDoesNotRevokeOtherProjects() async throws {
    let (dir, _, original, store) = try await fixture()
    let other = try directory()
    var record = original
    record.projects.append(CredentialProject(url: other))
    let a = try await store.issue(name: "A", project: dir.path, credential: record, days: 1)
    let b = try await store.issue(name: "B", project: other.path, credential: record, days: 1)
    try await store.revokeProject(dir.path)
    do {
      _ = try await store.validate(token: a.token, project: dir.path)
      XCTFail()
    } catch { XCTAssertEqual(error as? GrantError, .revoked) }
    let active = try await store.validate(token: b.token, project: other.path)
    XCTAssertEqual(active.id, b.id)
  }
  func testLegacyReminderDefaultsAndTemporaryTokenRedaction() throws {
    var record = credential(try directory())
    record.reminderDays = nil
    record.remindersEnabled = true
    record.expiresAt = Date().addingTimeInterval(86400)
    XCTAssertNoThrow(try record.validate())
    let token = "nva_" + String(repeating: "a", count: 43)
    let preview = SecretRedactor.redact("A temporary grant: " + token)
    XCTAssertFalse(preview.text.contains(token))
    XCTAssertGreaterThan(preview.count, 0)
  }
}
