import Foundation
import Security

public enum CredentialKind: String, Codable, CaseIterable, Sendable {
    case api = "API 凭证", server = "服务器"
}
public enum ServerAuthentication: String, Codable, CaseIterable, Sendable {
    case password = "密码", sshKey = "SSH 密钥"
}
public struct CredentialProject: Codable, Hashable, Sendable {
    public var path: String
    public var name: String
    public init(url: URL) { path = url.standardizedFileURL.path; name = url.lastPathComponent }
}
public struct CredentialRecord: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var kind: CredentialKind = .api
    public var name = ""
    public var environment = "开发"
    public var provider = ""
    public var address = ""
    public var variable = ""
    public var port = 22
    public var username = ""
    public var authentication: ServerAuthentication = .sshKey
    public var keyPath = ""
    public var deployPath = ""
    public var projects: [CredentialProject] = []
    public var secretID: UUID?
    public var updated = Date()
    public var addedAt: Date? = Date()
    public var expiresAt: Date?
    public var rotateAt: Date?
    public var remindersEnabled: Bool? = false
    public var reminderDays: [Int]? = [7, 1, 0]
    public init() {}
    public var needsSecret: Bool { kind == .api || authentication == .password }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.invalid(L("请填写名称")) }
        if remindersEnabled == true {
            guard expiresAt != nil || rotateAt != nil else { throw VaultError.invalid(L("请设置到期或轮换日期")) }
            let days = reminderDays ?? [7, 1, 0]
            guard !days.isEmpty, days.allSatisfy({ (0...30).contains($0) }) else { throw VaultError.invalid(L("请选择提醒时间")) }
        }
        guard !address.contains("\n"), !address.contains("\r") else { throw VaultError.invalid(L("地址不能包含换行")) }
        if kind == .api {
            guard let url = URLComponents(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
            else { throw VaultError.invalid(L("服务地址需为不含密码、查询参数的 HTTP(S) 地址")) }
            let expression = #"^[A-Za-z_][A-Za-z0-9_]*$"#
            guard variable.range(of: expression, options: .regularExpression) != nil else { throw VaultError.invalid(L("请填写有效环境变量名，如 API_TOKEN")) }
        } else {
            guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !address.contains("://"), !address.contains("@"), !address.contains("/") else { throw VaultError.invalid(L("请填写服务器主机名或 IP，不含用户名和协议")) }
            guard (1...65535).contains(port), !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.invalid(L("请检查端口和用户名")) }
            if authentication == .sshKey && keyPath.isEmpty { throw VaultError.invalid(L("请选择 SSH 密钥文件")) }
        }
    }
}
public enum VaultError: LocalizedError {
    case invalid(String), keychain(OSStatus), missing
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .keychain(let status): return L("钥匙串操作未完成（\(status)）")
        case .missing: return L("找不到此凭证，可能已在其他窗口更新")
        }
    }
}
public protocol CredentialSecretStore: Sendable {
    func put(_ value: String, id: UUID) throws
    func get(id: UUID) throws -> String
    func remove(id: UUID) throws
}
public struct KeychainCredentialStore: CredentialSecretStore {
    private let service: String
    public init(service: String = "com.novatechai.context.credentials") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false,
        ]
    }
    public func put(_ value: String, id: UUID) throws {
        var attributes = query(id)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrLabel as String] = L("Nova Context 凭证")
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }
    public func get(id: UUID) throws -> String {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw VaultError.invalid(L("无法读取凭证")) }
        return value
    }
    public func remove(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}

/// Serializes local metadata and secret changes. Secret values never enter the metadata file.
public actor CredentialVault {
    private let url: URL
    private let secrets: any CredentialSecretStore
    public init(url: URL, secrets: any CredentialSecretStore = KeychainCredentialStore()) { self.url = url; self.secrets = secrets }
    public func records() throws -> [CredentialRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CredentialRecord].self, from: Data(contentsOf: url))
    }
    private func write(_ records: [CredentialRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ record: CredentialRecord, secret: String?) throws -> [CredentialRecord] {
        try record.validate()
        var all = try records()
        let old = all.first { $0.id == record.id }
        var updated = record
        updated.secretID = old?.secretID
        var added: UUID?
        if record.needsSecret {
            if let secret, !secret.isEmpty {
                let id = UUID(); try secrets.put(secret, id: id); added = id; updated.secretID = id
            } else if updated.secretID == nil {
                throw VaultError.invalid(L("请填写 Token 或密码"))
            }
        } else {
            updated.secretID = nil
        }
        updated.addedAt = old != nil ? old?.addedAt : record.addedAt
        updated.updated = Date()
        all.removeAll { $0.id == record.id }; all.append(updated)
        do { try write(all) } catch { if let added { try? secrets.remove(id: added) }; throw error }
        // Committed records remain usable even if obsolete-item cleanup is declined by the system.
        if let oldID = old?.secretID, oldID != updated.secretID { try? secrets.remove(id: oldID) }
        return all
    }
    public func reveal(_ id: UUID) throws -> String {
        guard let record = try records().first(where: { $0.id == id }), let secret = record.secretID else { throw VaultError.missing }
        return try secrets.get(id: secret)
    }
    public func apiCredential(_ id: UUID, project: String, revision: String? = nil, now: Date = Date()) throws -> CredentialRecord {
        guard let record = try records().first(where: { $0.id == id }), record.kind == .api,
            record.projects.contains(where: { $0.path == project }), record.secretID != nil,
            record.expiresAt.map({ $0 > now }) ?? true else { throw GrantError.credentialUnavailable }
        guard GitHubIdentityAdapter.accepts(record.address) else { throw GrantError.credentialUnavailable }
        if let revision, CredentialRevision.of(record) != revision { throw GrantError.credentialChanged }
        return record
    }
    public func authorizedAPISecret(_ id: UUID, project: String, revision: String, now: Date = Date()) throws -> String {
        let record = try apiCredential(id, project: project, revision: revision, now: now)
        guard let key = record.secretID else { throw GrantError.credentialUnavailable }
        return try secrets.get(id: key)
    }
    public func link(_ id: UUID, project: CredentialProject, linked: Bool) throws -> [CredentialRecord] {
        var all = try records()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw VaultError.missing }
        all[index].projects.removeAll { $0.path == project.path }
        if linked { all[index].projects.append(project) }
        try write(all); return all
    }
    public func delete(_ id: UUID) throws -> [CredentialRecord] {
        var all = try records()
        guard let record = all.first(where: { $0.id == id }) else { throw VaultError.missing }
        let original = all
        all.removeAll { $0.id == id }
        try write(all)
        do {
            if let secret = record.secretID { try secrets.remove(id: secret) }
        } catch {
            try write(original)
            throw error
        }
        return all
    }
    /// Whitelisted metadata only: never exports secret values or internal Keychain IDs.
    public static func environmentDescription(records: [CredentialRecord], project: CredentialProject, configuration: ProjectCard? = nil) throws -> Data {
        struct Reference: Encodable {
            var id: UUID; var name: String; var type: CredentialKind; var environment: String
            var address: String; var variable: String?; var port: Int?; var username: String?
            var authentication: ServerAuthentication?; var keyPath: String?; var deployPath: String?
        }
        struct Manifest: Encodable { var version = 2; var project: String; var environment: String?; var runtime: String?; var credentials: [Reference] }
        let references = records.filter { $0.projects.contains(where: { $0.path == project.path }) }.map {
            Reference(
                id: $0.id, name: $0.name, type: $0.kind, environment: $0.environment, address: $0.address,
                variable: $0.kind == .api ? $0.variable : nil, port: $0.kind == .server ? $0.port : nil,
                username: $0.kind == .server ? $0.username : nil, authentication: $0.kind == .server ? $0.authentication : nil,
                keyPath: $0.kind == .server && $0.authentication == .sshKey ? $0.keyPath : nil,
                deployPath: $0.kind == .server ? $0.deployPath : nil)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Manifest(project: project.name, environment: configuration?.path == project.path ? configuration?.environment : nil, runtime: configuration?.path == project.path ? configuration?.runtime : nil, credentials: references))
    }
}
