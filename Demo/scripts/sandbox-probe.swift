import Foundation
import Darwin

/// Synthetic engineering check only. Not linked into the product and never accesses credentials.
@main struct SandboxProbe {
    static func main() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let url = ServiceEndpoint.socket(home: home, fallback: home, sandboxed: true).deletingLastPathComponent().appendingPathComponent("q" + String(getpid()) + ".sock")
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outside = ProcessInfo.processInfo.environment["NOVA_PROBE_OUTSIDE"] ?? "/nonexistent"
        let denied = (try? Data(contentsOf: URL(fileURLWithPath: outside))) == nil
        guard ServiceEndpoint.fits(url) else { throw NSError(domain: "ProbePath", code: 1) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "ProbeSocket", code: Int(errno)) }
        defer { close(fd); unlink(url.path) }
        var address = sockaddr_un(); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 1) == 0 else { throw NSError(domain: "ProbeBind", code: Int(errno)) }
        let result: [String: Any] = ["socket": url.path, "bytes": url.path.utf8.count, "home": home.path, "outside_read_denied": denied]
        let line = String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)! + "\n"
        print(line, terminator: ""); fflush(stdout)
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 8000) > 0 else { return }
        let client = accept(fd, nil, nil); guard client >= 0 else { return }; defer { close(client) }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = read(client, &bytes, bytes.count)
        guard count > 0 else { return }
        let data = Data(bytes.prefix(count))
        let response: Data
        if ProcessInfo.processInfo.environment["NOVA_PROBE_NATIVE"] == "1",
           let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           request["operation"] as? String == "github.identity", let id = request["requestID"] as? String {
            response = try JSONSerialization.data(withJSONObject: ["version": 1, "requestID": id, "ok": true, "result": ["login": "synthetic-user", "id": 42, "type": "User"]]) + Data([10])
        } else if String(decoding: data, as: UTF8.self) == "ping\n" { response = Data("pong\n".utf8) }
        else { return }
        _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
    }
}
