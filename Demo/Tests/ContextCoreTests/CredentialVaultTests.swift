import XCTest
@testable import ContextCore

private final class FakeSecretStore: CredentialSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    var rejectDelete = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func put(_ value: String, id: UUID) throws { lock.lock(); defer { lock.unlock() }; values[id] = value }
    func get(id: UUID) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[id] else { throw VaultError.missing }; return value
    }
    func remove(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectDelete { throw VaultError.invalid("test denial") }; values[id] = nil
    }
}
final class CredentialVaultTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("Credentials/vault.json")
    }
    private func api() -> CredentialRecord {
        var value = CredentialRecord(); value.name = "Synthetic API"; value.variable = "TEST_API_TOKEN"; value.address = "https://example.invalid/v1"; return value
    }
    func testSecretsNeverEnterMetadataAndReopenWorks() async throws {
        let url = try location(), store = FakeSecretStore()
        let vault = CredentialVault(url: url, secrets: store)
        let record = api()
        let saved = try await vault.save(record, secret: "synthetic-test-secret")
        XCTAssertEqual(saved.count, 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("synthetic-test-secret"))
        let reopened = CredentialVault(url: url, secrets: store)
        let value = try await reopened.reveal(record.id)
        XCTAssertEqual(value, "synthetic-test-secret")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testBlankEditPreservesSecretAndRotationReplacesIt() async throws {
        let store = FakeSecretStore()
        // A dedicated repository keeps the fake store observable without inspecting any system items.
        let observed = CredentialVault(url: try location(), secrets: store)
        var record = api()
        let first = try await observed.save(record, secret: "first-synthetic")
        record.name = "Renamed"
        let second = try await observed.save(record, secret: nil)
        XCTAssertEqual(first.first?.secretID, second.first?.secretID)
        let third = try await observed.save(record, secret: "second-synthetic")
        XCTAssertNotEqual(first.first?.secretID, third.first?.secretID)
        XCTAssertEqual(store.count, 1)
        let value = try await observed.reveal(record.id); XCTAssertEqual(value, "second-synthetic")
    }
    func testLinksDeduplicateAndManifestContainsOnlyCurrentProject() async throws {
        let vault = CredentialVault(url: try location(), secrets: FakeSecretStore())
        let project = CredentialProject(url: URL(fileURLWithPath: "/synthetic/project-a"))
        let record = api(); var other = api(); other.name = "Unrelated"
        _ = try await vault.save(record, secret: "synthetic-one")
        _ = try await vault.save(other, secret: "synthetic-two")
        _ = try await vault.link(record.id, project: project, linked: true)
        let records = try await vault.link(record.id, project: project, linked: true)
        XCTAssertEqual(records.first(where: { $0.id == record.id })?.projects.count, 1)
        let data = try CredentialVault.environmentDescription(records: records, project: project)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-one")); XCTAssertFalse(text.contains("secretID")); XCTAssertFalse(text.contains("Unrelated"))
        XCTAssertTrue(text.contains("TEST_API_TOKEN"))
        let unlinked = try await vault.link(record.id, project: project, linked: false)
        XCTAssertTrue(unlinked.first(where: { $0.id == record.id })!.projects.isEmpty)
    }
    func testSSHKeyOnlyStoresPathAndRequiresNoSecret() async throws {
        let store = FakeSecretStore(), vaultURL = try location()
        let vault = CredentialVault(url: vaultURL, secrets: store)
        var record = CredentialRecord(); record.kind = .server; record.name = "Test SSH"; record.address = "example.invalid"
        record.username = "test"; record.keyPath = "/synthetic/id_ed25519"
        let records = try await vault.save(record, secret: nil)
        XCTAssertNil(records.first?.secretID); XCTAssertEqual(store.count, 0)
        XCTAssertTrue(try String(contentsOf: vaultURL, encoding: .utf8).contains("id_ed25519"))
    }
    func testFailedMetadataWriteRollsBackNewSecret() async throws {
        let url = try location(), store = FakeSecretStore()
        // Parent is a regular file, making metadata creation fail after secret storage.
        try Data("fixture".utf8).write(to: url.deletingLastPathComponent())
        let vault = CredentialVault(url: url, secrets: store)
        do { _ = try await vault.save(api(), secret: "rollback-synthetic"); XCTFail("Expected write failure") } catch {}
        XCTAssertEqual(store.count, 0)
    }
    func testRefusedDeletionKeepsMetadataAndCredential() async throws {
        let store = FakeSecretStore()
        let observed = CredentialVault(url: try location(), secrets: store); let record = api()
        _ = try await observed.save(record, secret: "delete-synthetic"); store.rejectDelete = true
        do { _ = try await observed.delete(record.id); XCTFail("Expected denial") } catch {}
        let retained = try await observed.records(); XCTAssertEqual(retained.count, 1)
        store.rejectDelete = false
        let removed = try await observed.delete(record.id); XCTAssertTrue(removed.isEmpty); XCTAssertEqual(store.count, 0)
    }
    func testValidationRejectsSecretInURLAndInvalidFields() throws {
        var record = api(); record.address = "https://user:password@example.invalid"; XCTAssertThrowsError(try record.validate())
        record.address = "https://example.invalid?token=secret"; XCTAssertThrowsError(try record.validate())
        record.address = "https://example.invalid"; record.variable = "BAD-VAR"; XCTAssertThrowsError(try record.validate())
        record.kind = .server; record.address = "example.invalid"; record.username = "test"; record.port = 0
        XCTAssertThrowsError(try record.validate())
    }
    func testMalformedMetadataCannotBeOverwritten() async throws {
        let url = try location(), store = FakeSecretStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("invalid".utf8); try malformed.write(to: url)
        let vault = CredentialVault(url: url, secrets: store)
        do { _ = try await vault.save(api(), secret: "not-written"); XCTFail("Expected invalid metadata") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), malformed); XCTAssertEqual(store.count, 0)
    }
    func testLocalKeychainRoundTripOptIn() throws {
        guard ProcessInfo.processInfo.environment["NOVA_TEST_KEYCHAIN"] == "1" else { throw XCTSkip("Opt-in synthetic local Keychain test") }
        let store = KeychainCredentialStore(service: "com.novatechai.context.test." + UUID().uuidString)
        let id = UUID(); defer { try? store.remove(id: id) }
        try store.put("synthetic-keychain-fixture", id: id)
        XCTAssertEqual(try store.get(id: id), "synthetic-keychain-fixture")
        try store.remove(id: id)
        XCTAssertThrowsError(try store.get(id: id))
    }
}
