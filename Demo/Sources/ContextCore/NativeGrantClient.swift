import Foundation
import Darwin

/// Bundled native Agent entry point. Reads a temporary capability from stdin, never argv or Keychain.
public enum NativeGrantClient {
    private struct Export: Decodable { let version: Int; let socket: String; let project: String; let operation: String; let token: String }
    private static func failure(_ code: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "ok": false, "error": code])
    }
    public static func run() -> Int32 {
        do {
            var info = stat(); guard fstat(STDIN_FILENO, &info) == 0 else { throw GrantError.invalidRequest }
            let type = info.st_mode & S_IFMT
            guard type == S_IFIFO || (type == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o077 == 0) else { throw GrantError.denied }
            let input = try readFrame(STDIN_FILENO, limit: 16384, deadline: Date().addingTimeInterval(22), newline: false)
            let response = try request(input)
            FileHandle.standardOutput.write(response + Data([10]))
            return (try? JSONDecoder().decode(GrantResponse.self, from: response).ok) == true ? 0 : 1
        } catch {
            FileHandle.standardOutput.write(failure("serviceUnavailable") + Data([10])); return 1
        }
    }
    public static func request(_ data: Data, requestID: UUID = UUID()) throws -> Data {
        guard data.count <= 16384, let grant = try? JSONDecoder().decode(Export.self, from: data), grant.version == 1,
            grant.operation == "github.identity", grant.socket.hasPrefix("/"), !grant.socket.utf8.contains(0),
            grant.socket.utf8.count < 104, grant.token.hasPrefix("nva_"), grant.token.utf8.count == 47,
            grant.token.dropFirst(4).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), !grant.project.isEmpty else { throw GrantError.invalidRequest }
        var info = stat(), parent = stat()
        guard lstat(grant.socket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
            lstat(URL(fileURLWithPath: grant.socket).deletingLastPathComponent().path, &parent) == 0,
            parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else { throw GrantError.denied }
        let deadline = Date().addingTimeInterval(22)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw GrantError.busy }
        defer { close(fd) }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
            fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw GrantError.busy }
        var address = sockaddr_un(); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(grant.socket.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw GrantError.busy }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw GrantError.busy }
        }
        // Check the connected peer as well as the filesystem before forwarding the capability.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw GrantError.denied }
        let payload = try JSONEncoder().encode(GrantRequest(requestID: requestID, token: grant.token, project: grant.project)) + Data([10])
        guard payload.count <= 4097 else { throw GrantError.invalidRequest }
        var sent = 0
        while sent < payload.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let n = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), payload.count - sent) }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard n > 0 else { throw GrantError.busy }; sent += n
        }
        let bytes = try readFrame(fd, limit: 16384, deadline: deadline, newline: true)
        let reply = try JSONDecoder().decode(GrantResponse.self, from: bytes)
        guard reply.version == 1, reply.requestID == requestID else { throw GrantError.invalidRequest }
        if let result = reply.result {
            _ = try GitHubIdentityAdapter.decode(JSONEncoder().encode(result), excluding: grant.token)
        }
        if let error = reply.error {
            guard GrantError(rawValue: error) != nil else { throw GrantError.invalidRequest }
        }
        return try JSONEncoder().encode(reply)
    }
    private static func wait(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw GrantError.busy }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let count = poll(&item, 1, Int32(min(22000, max(1, left * 1000))))
            if count < 0 && errno == EINTR { continue }
            guard count > 0, item.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw GrantError.busy }
            return
        }
    }
    private static func readFrame(_ fd: Int32, limit: Int, deadline: Date, newline: Bool) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while data.count <= limit {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard n >= 0 else { throw GrantError.busy }
            if n == 0 { if !newline { return data }; throw GrantError.invalidRequest }
            data.append(contentsOf: buffer.prefix(n))
            if newline, let end = data.firstIndex(of: 10) { guard end <= limit else { throw GrantError.invalidRequest }; return data.prefix(upTo: end) }
        }
        throw GrantError.invalidRequest
    }
}
