import CryptoKit
import Darwin
import XCTest

@testable import ContextCore

private final class StressSecrets: CredentialSecretStore, @unchecked Sendable {
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
private actor StressAPI: IdentityTransport {
  var calls = 0, active = 0, peak = 0
  let delay: UInt64
  init(delay: UInt64 = 0) { self.delay = delay }
  func identity(secret: String) async throws -> GitHubIdentity {
    guard secret == "synthetic-stress-original-key" else { throw GrantError.credentialUnavailable }
    calls += 1
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
    return GitHubIdentity(login: "stress-test", id: 7, type: "User")
  }
}
private struct StressFixture {
  let root: URL, vault: CredentialVault, credential: CredentialRecord, grants: TemporaryGrantStore
  let api: StressAPI, broker: LocalGrantBroker, issued: IssuedGrant
}
private struct Probe: Sendable {
  let ms: Double
  let outcome: String
}
private struct ResourceSample: Codable {
  let residentMB: Double, peakResidentRaw: Int64, descriptors: Int, cpuSeconds: Double
  static func sample() -> Self {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
        usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    return Self(
      residentMB: Double(info.resident_size) / 1_048_576, peakResidentRaw: Int64(usage.ru_maxrss),
      descriptors: (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1,
      cpuSeconds: cpu)
  }
}
private struct LoadMetric: Codable {
  let name: String, requests: Int, workers: Int, seconds: Double, requestsPerSecond: Double
  let acceptedP95ms: Double, successfulRequestsPerSecond: Double
  let success: Int, outcomes: [String: Int], p50ms: Double, p95ms: Double, p99ms: Double,
    maxMS: Double
  let before: ResourceSample, after: ResourceSample
  init(
    name: String, workers: Int, probes: [Probe], seconds: Double, before: ResourceSample,
    after: ResourceSample
  ) {
    self.name = name
    self.workers = workers
    self.requests = probes.count
    self.seconds = seconds
    self.requestsPerSecond = Double(probes.count) / max(seconds, 0.000001)
    self.success = probes.filter { $0.outcome == "ok" }.count
    self.successfulRequestsPerSecond = Double(self.success) / max(seconds, 0.000001)
    let accepted = probes.filter { $0.outcome == "ok" }.map(\.ms).sorted()
    self.acceptedP95ms =
      accepted.isEmpty
      ? 0 : accepted[min(accepted.count - 1, Int(Double(accepted.count - 1) * 0.95))]
    self.outcomes = Dictionary(grouping: probes, by: \.outcome).mapValues(\.count)
    let sorted = probes.map(\.ms).sorted()
    func p(_ value: Double) -> Double {
      sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * value))]
    }
    p50ms = p(0.5)
    p95ms = p(0.95)
    p99ms = p(0.99)
    maxMS = sorted.last ?? 0
    self.before = before
    self.after = after
  }
}
private struct StressReport: Codable {
  let schema = 1
  let os: String, cpuCount: Int, physicalMemoryGB: Double
  var validity: [String: Bool] = [:]
  var stages: [LoadMetric] = []
  var fileMetrics: [String: Double] = [:]
  var finalAPIConcurrency = 0
  var assertionFailures = 0
}

final class GrantStressTests: XCTestCase {
  private func fixture(delay: UInt64 = 0, expiry: Date? = nil, realKeychain: Bool = false)
    async throws -> StressFixture
  {
    let root = URL(fileURLWithPath: "/tmp/nvs-load-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let secrets: any CredentialSecretStore =
      realKeychain
      ? KeychainCredentialStore(service: "com.novatechai.context.stress." + UUID().uuidString)
      : StressSecrets()
    let vault = CredentialVault(url: root.appendingPathComponent("vault.json"), secrets: secrets)
    var record = CredentialRecord()
    record.name = "Synthetic stress API"
    record.address = "https://api.github.com"
    record.variable = "STRESS_API_TOKEN"
    record.projects = [CredentialProject(url: root)]
    record.expiresAt = expiry
    _ = try await vault.save(record, secret: "synthetic-stress-original-key")
    let saved = try await vault.records()[0]
    let store = TemporaryGrantStore(url: root.appendingPathComponent("grants.json"))
    if realKeychain, let id = saved.secretID {
      addTeardownBlock { try? secrets.remove(id: id) }
    }
    let issued = try await store.issue(
      name: "Stress", project: root.path, credential: saved, days: 1)
    let api = StressAPI(delay: delay)
    let broker = LocalGrantBroker(grants: store, vault: vault, transport: api)
    await broker.setEnabled(true)
    return StressFixture(
      root: root, vault: vault, credential: saved, grants: store, api: api, broker: broker,
      issued: issued)
  }
  private func input(_ f: StressFixture, requestID: UUID = UUID(), token: String? = nil) throws
    -> Data
  {
    try JSONEncoder().encode(
      GrantRequest(requestID: requestID, token: token ?? f.issued.token, project: f.root.path))
  }
  private func response(_ data: Data) throws -> GrantResponse {
    try JSONDecoder().decode(GrantResponse.self, from: data)
  }
  private static func ticks() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
  }
  private static func idleSocket(_ path: URL) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GrantError.busy }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(path.path.utf8) + [0])
    }
    let result = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw GrantError.busy
    }
    return fd
  }
  private static func socketProbe(_ path: URL, data: Data) -> Probe {
    let start = ticks()
    func result(_ code: String) -> Probe { Probe(ms: (ticks() - start) * 1000, outcome: code) }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return result("socket") }
    defer { Darwin.close(fd) }
    var noSignal: Int32 = 1
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(path.path.utf8) + [0])
    }
    let connected = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { return result("connect") }
    var framed = data
    framed.append(10)
    let sent = framed.withUnsafeBytes { bytes -> Bool in
      var count = 0
      while count < bytes.count {
        let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count, 0)
        guard sent > 0 else { return false }
        count += sent
      }
      return true
    }
    guard sent else { return result("closed") }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 2048)
    while output.count < 16384 {
      let read = Darwin.recv(fd, &buffer, buffer.count, 0)
      guard read > 0 else { return result(errno == EAGAIN ? "timeout" : "closed") }
      output.append(contentsOf: buffer.prefix(read))
      if let end = output.firstIndex(of: 10) {
        guard let response = try? JSONDecoder().decode(GrantResponse.self, from: output[..<end])
        else { return result("invalidResponse") }
        return result(response.ok ? "ok" : (response.error ?? "invalidResponse"))
      }
    }
    return result("oversizedResponse")
  }
  private func socketProbe(_ path: URL, data: Data) async -> Probe {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: Self.socketProbe(path, data: data))
      }
    }
  }
  private func load(
    _ f: StressFixture, name: String, count: Int, workers: Int, socket: URL? = nil,
    repeatedID: UUID? = nil
  ) async throws -> LoadMetric {
    let before = ResourceSample.sample()
    let start = Self.ticks()
    let probes = try await withThrowingTaskGroup(of: [Probe].self) { group in
      for worker in 0..<workers {
        group.addTask {
          var output: [Probe] = []
          for _ in stride(from: worker, to: count, by: workers) {
            let data = try self.input(f, requestID: repeatedID ?? UUID())
            if let socket {
              output.append(await self.socketProbe(socket, data: data))
            } else {
              let begin = Self.ticks()
              let response = try self.response(await f.broker.handle(data))
              output.append(
                Probe(
                  ms: (Self.ticks() - begin) * 1000,
                  outcome: response.ok ? "ok" : response.error ?? "invalidResponse"))
            }
          }
          return output
        }
      }
      var all: [Probe] = []
      for try await batch in group { all += batch }
      return all
    }
    let elapsed = Self.ticks() - start
    try await Task.sleep(for: .milliseconds(100))
    let metric = LoadMetric(
      name: name, workers: workers, probes: probes, seconds: elapsed, before: before,
      after: .sample())
    print(
      "LOAD_STAGE \(name) attempts=\(count) success=\(metric.success) p95ms=\(metric.p95ms) seconds=\(elapsed)"
    )
    return metric
  }
  func testOptInRealKeychainTemporaryGrantValidity() async throws {
    guard ProcessInfo.processInfo.environment["NOVA_TEST_KEYCHAIN"] == "1" else {
      throw XCTSkip("Opt-in real Keychain using a new synthetic item, never user credentials")
    }
    let f = try await fixture(realKeychain: true)
    let path = f.root.appendingPathComponent("service/api.sock")
    let server = LocalSocketService(url: path, broker: f.broker)
    try server.start()
    defer { server.stop() }
    let first = await socketProbe(path, data: try input(f))
    XCTAssertEqual(first.outcome, "ok")
    try await f.grants.revoke(f.issued.id)
    let revoked = await socketProbe(path, data: try input(f))
    XCTAssertEqual(revoked.outcome, "revoked")
    let replacement = try await f.grants.issue(
      name: "Keychain replacement", project: f.root.path, credential: f.credential, days: 1,
      replacing: f.issued.id)
    let renewed = await socketProbe(path, data: try input(f, token: replacement.token))
    XCTAssertEqual(renewed.outcome, "ok")
    _ = try await f.vault.delete(f.credential.id)
    let deleted = await socketProbe(path, data: try input(f, token: replacement.token))
    XCTAssertEqual(deleted.outcome, "credentialUnavailable")
    let apiCalls = await f.api.calls
    XCTAssertEqual(apiCalls, 2)
    let leaked = try String(
      contentsOf: f.root.appendingPathComponent("grants.json"), encoding: .utf8)
    XCTAssertFalse(leaked.contains("synthetic-stress-original-key"))
    XCTAssertFalse(leaked.contains(replacement.token))
  }
  func testFourClientsCanImmediatelyReconnectWithoutFalseOverload() async throws {
    let f = try await fixture(delay: 1_000_000)
    let path = f.root.appendingPathComponent("service/api.sock")
    let server = LocalSocketService(url: path, broker: f.broker)
    try server.start()
    defer { server.stop() }
    let metric = try await load(
      f, name: "reconnect-regression", count: 400, workers: 4, socket: path)
    XCTAssertEqual(metric.success, 400)
    let peak = await f.api.peak
    XCTAssertLessThanOrEqual(peak, 4)
  }
  func testOptInValidityAndStress() async throws {
    guard ProcessInfo.processInfo.environment["NOVA_RUN_STRESS"] == "1" else {
      throw XCTSkip("Set NOVA_RUN_STRESS=1 for bounded local synthetic stress")
    }
    var report = StressReport(
      os: ProcessInfo.processInfo.operatingSystemVersionString,
      cpuCount: ProcessInfo.processInfo.processorCount,
      physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
    let f = try await fixture()
    let valid = try response(await f.broker.handle(input(f)))
    XCTAssertTrue(valid.ok)
    report.validity["initialValid"] = valid.ok
    var wrong = GrantRequest(token: f.issued.token, project: "/different-project")
    let denied = try response(await f.broker.handle(JSONEncoder().encode(wrong)))
    XCTAssertEqual(denied.error, "denied")
    report.validity["projectIsolation"] = denied.error == "denied"
    wrong = GrantRequest(
      token: String(f.issued.token.dropLast()) + (f.issued.token.last == "a" ? "b" : "a"),
      project: f.root.path)
    let forged = try response(await f.broker.handle(JSONEncoder().encode(wrong)))
    XCTAssertEqual(forged.error, "denied")
    report.validity["tamperedRejected"] = forged.error == "denied"
    let reloaded = TemporaryGrantStore(url: f.root.appendingPathComponent("grants.json"))
    let persisted = try await reloaded.validate(token: f.issued.token, project: f.root.path)
    report.validity["persistedDigestValid"] = persisted.id == f.issued.id
    XCTAssertEqual(persisted.id, f.issued.id)
    let rotated = try await f.grants.issue(
      name: "Rotated", project: f.root.path, credential: f.credential, days: 1,
      replacing: f.issued.id)
    let old = try response(await f.broker.handle(input(f)))
    let new = try response(await f.broker.handle(input(f, token: rotated.token)))
    XCTAssertEqual(old.error, "revoked")
    XCTAssertTrue(new.ok)
    report.validity["rotationRejectsOldAndAcceptsNew"] = old.error == "revoked" && new.ok
    try await f.grants.revoke(rotated.id)
    let revoked = try response(await f.broker.handle(input(f, token: rotated.token)))
    XCTAssertEqual(revoked.error, "revoked")
    report.validity["manualRevoke"] = revoked.error == "revoked"
    let expiring = try await fixture(expiry: Date().addingTimeInterval(2))
    let beforeExpiry = try response(await expiring.broker.handle(input(expiring)))
    try await Task.sleep(for: .milliseconds(2200))
    let afterExpiry = try response(await expiring.broker.handle(input(expiring)))
    XCTAssertTrue(beforeExpiry.ok)
    XCTAssertEqual(afterExpiry.error, "expired")
    report.validity["wallClockExpiry"] = beforeExpiry.ok && afterExpiry.error == "expired"
    let serial = try await fixture()
    let normal = try await load(serial, name: "broker-sequential", count: 1000, workers: 1)
    XCTAssertEqual(normal.success, 1000)
    report.stages.append(normal)
    let socketFixture = try await fixture(delay: 10_000_000)
    let path = socketFixture.root.appendingPathComponent("service/api.sock")
    let server = LocalSocketService(url: path, broker: socketFixture.broker)
    try server.start()
    defer { server.stop() }
    let baselineFD = ResourceSample.sample().descriptors
    for (workers, total) in [(1, 100), (4, 1000), (16, 512), (64, 512)] {
      let metric = try await load(
        socketFixture, name: "socket-\(workers)-workers", count: total, workers: workers,
        socket: path)
      if workers <= 4 { XCTAssertEqual(metric.success, total) }
      XCTAssertNil(metric.outcomes["invalidResponse"])
      XCTAssertNil(metric.outcomes["oversizedResponse"])
      XCTAssertLessThanOrEqual(metric.after.descriptors, baselineFD + 3)
      report.stages.append(metric)
    }
    let soak = try await load(
      socketFixture, name: "socket-4-workers-soak", count: 5000, workers: 4, socket: path)
    XCTAssertEqual(soak.success, 5000)
    XCTAssertLessThanOrEqual(soak.after.descriptors, baselineFD + 3)
    XCTAssertLessThan(soak.after.residentMB - soak.before.residentMB, 32)
    report.stages.append(soak)
    let recordsAfterSoak = try await socketFixture.grants.records()
    XCTAssertEqual(recordsAfterSoak.first?.requestIDs.count, 128)
    let persistedText = try String(
      contentsOf: socketFixture.root.appendingPathComponent("grants.json"), encoding: .utf8)
    XCTAssertFalse(persistedText.contains(socketFixture.issued.token))
    XCTAssertFalse(persistedText.contains("synthetic-stress-original-key"))
    report.validity["boundedHistoryAndNoTokenPersistenceAfterSoak"] =
      recordsAfterSoak.first?.requestIDs.count == 128
    let apiPeak = await socketFixture.api.peak
    report.finalAPIConcurrency = apiPeak
    XCTAssertLessThanOrEqual(apiPeak, 4)
    let replay = try await fixture(delay: 5_000_000)
    let repeated = try await load(
      replay, name: "duplicate-request-burst", count: 256, workers: 16, repeatedID: UUID())
    let actualCalls = await replay.api.calls
    XCTAssertEqual(actualCalls, 1)
    XCTAssertEqual(repeated.success, 1)
    report.validity["concurrentReplayOnlyOneAPIExecution"] = actualCalls == 1
    report.stages.append(repeated)
    var idle: [Int32] = []
    for _ in 0..<4 { idle.append(try Self.idleSocket(path)) }
    try await Task.sleep(for: .milliseconds(150))
    let whileSaturated = await socketProbe(path, data: try input(socketFixture))
    XCTAssertNotEqual(whileSaturated.outcome, "ok")
    try await Task.sleep(for: .milliseconds(3300))
    let afterSlowTimeout = await socketProbe(path, data: try input(socketFixture))
    idle.forEach { Darwin.close($0) }
    XCTAssertEqual(afterSlowTimeout.outcome, "ok")
    report.validity["slowClientTimeoutRecovery"] =
      afterSlowTimeout.outcome == "ok" && whileSaturated.outcome != "ok"
    let beforeFlood = await socketFixture.api.calls
    let bad = Data(repeating: 120, count: 5000)
    for _ in 0..<100 { _ = await socketProbe(path, data: bad) }
    let afterFlood = await socketFixture.api.calls
    XCTAssertEqual(beforeFlood, afterFlood)
    report.validity["oversizedFloodNeverReachesAPI"] = beforeFlood == afterFlood
    let recovered = await socketProbe(path, data: try input(socketFixture))
    XCTAssertEqual(recovered.outcome, "ok")
    report.validity["recoversAfterOversizedFlood"] = recovered.outcome == "ok"
    // Seed the supported maximum registry once, avoiding quadratic fixture creation writes.
    let large = try await fixture()
    var records = [large.issued.record]
    for number in 1..<1000 {
      records.append(
        TemporaryGrant(
          id: UUID(), name: "Synthetic \(number)", project: large.root.path,
          credentialID: large.credential.id,
          credentialRevision: CredentialRevision.of(large.credential),
          createdAt: Date(), expiresAt: Date().addingTimeInterval(86400), revokedAt: nil,
          tokenDigest: Data(SHA256.hash(data: Data("unusable-fixture-\(number)".utf8))),
          lastUsedAt: nil, requestIDs: [], lastOutcome: nil))
    }
    try JSONEncoder().encode(records).write(
      to: large.root.appendingPathComponent("grants.json"), options: .atomic)
    do {
      _ = try await large.grants.issue(
        name: "Over capacity", project: large.root.path, credential: large.credential, days: 1)
      XCTFail("The documented 1000-record bound must hold")
    } catch { XCTAssertEqual(error as? GrantError, .busy) }
    let largeMetric = try await load(
      large, name: "registry-1000-sequential", count: 100, workers: 1)
    XCTAssertEqual(largeMetric.success, 100)
    report.stages.append(largeMetric)
    // A real disk fixture and repeated 100k in-memory projections, without using user files.
    let disk = large.root.appendingPathComponent("disk-fixture")
    try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    for folder in 0..<100 {
      let directory = disk.appendingPathComponent("folder-\(folder)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for file in 0..<100 {
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("file-\(file).txt"))
      }
    }
    let diskStart = Self.ticks()
    let scan = try ProjectFiles.scan(disk)
    report.fileMetrics["realDisk10000ScanSeconds"] = Self.ticks() - diskStart
    XCTAssertEqual(scan.files.count, 10000)
    XCTAssertFalse(scan.truncated)
    let indexStart = Self.ticks()
    let files = (0..<100_000).map {
      ProjectFile(path: "folder-\($0 % 100)/file-\($0).json", size: $0, modified: .distantPast)
    }
    let index = BrowserIndex(files: files)
    report.fileMetrics["metadata100000IndexSeconds"] = Self.ticks() - indexStart
    let searchStart = Self.ticks()
    for page in 0..<20 {
      let snapshot = try BrowserSnapshot.make(
        index: index, filter: BrowserFilter(), query: "file-", folder: "", fixed: false, pins: [],
        expanded: [], opened: [:], page: page)
      XCTAssertEqual(snapshot.rows.count, 200)
    }
    report.fileMetrics["metadata100000TwentySearchPagesSeconds"] = Self.ticks() - searchStart
    report.fileMetrics["residentAfterIndexMB"] = ResourceSample.sample().residentMB
    server.stop()
    try await Task.sleep(for: .milliseconds(200))
    report.validity["validityChecksPassed"] = report.validity.values.allSatisfy { $0 }
    report.assertionFailures = testRun?.failureCount ?? 0
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let reportPath =
      ProcessInfo.processInfo.environment["NOVA_STRESS_REPORT"] ?? "/tmp/nova-stress-report.json"
    try encoder.encode(report).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
    XCTAssertTrue(report.validity.values.allSatisfy { $0 })
    print("STRESS_REPORT_WRITTEN")
  }
}
