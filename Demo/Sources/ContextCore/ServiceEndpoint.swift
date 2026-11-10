import Foundation

public enum ServiceEndpoint {
    /// Container home is shorter and stable across launches; never use global /tmp for the listener.
    public static func socket(home: URL, fallback: URL, sandboxed: Bool) -> URL {
        sandboxed ? home.appendingPathComponent("tmp/nc/api.sock") : fallback.appendingPathComponent("Service/api.sock")
    }
    public static func fits(_ url: URL) -> Bool { url.path.utf8.count < 104 }
}
